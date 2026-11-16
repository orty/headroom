# Envoy config for the headroom-dashboard gateway (see README.md).
# Rendered by render-envoy.sh: every __NAME__ comes from .env.local or a
# default there. The proxy token is NOT rendered in: Envoy reads it at request
# time from the HEADROOM_PROXY_TOKEN env var (%ENVIRONMENT(...)%).
#
# Two kinds of routes:
# - Browser routes (/, /dashboard*, /stats*, /health), GET only. Easy Auth in
#   front has already signed the user in; Envoy adds the proxy token and
#   strips Cookie/Authorization, as the old Caddyfile did.
# - API routes (/v1/*, /api/*). Easy Auth excludes them (excludedPaths), so
#   Envoy authenticates: an Entra access token for this app registration in
#   x-headroom-gateway-token (Authorization keeps the caller's Anthropic
#   credential), with scope access_as_user (people) or app role
#   Headroom.Proxy (managed identities). The token is removed, the proxy
#   token added, and the caller identity forwarded as x-headroom-* tags.
# No admin listener: nothing can dump this config or the env at runtime.

static_resources:
  listeners:
  - name: gateway
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: gateway
          codec_type: AUTO
          server_header_transformation: PASS_THROUGH
          # SSE streams can sit silent for minutes while the model thinks.
          stream_idle_timeout: 900s
          # Match virtual hosts on the name alone, whatever port a client sends.
          strip_any_host_port: true
          request_timeout: 0s
          access_log:
          - name: envoy.access_loggers.stdout
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
              log_format:
                json_format:
                  event: gateway_access
                  method: "%REQ(:METHOD)%"
                  path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
                  status: "%RESPONSE_CODE%"
                  flags: "%RESPONSE_FLAGS%"
                  details: "%RESPONSE_CODE_DETAILS%"
                  duration_ms: "%DURATION%"
                  ttfb_ms: "%RESPONSE_DURATION%"
                  user: "%REQ(X-HEADROOM-USER)%"
                  principal: "%REQ(X-HEADROOM-PRINCIPAL)%"
                  app: "%REQ(X-HEADROOM-APP)%"
                  ua: "%REQ(USER-AGENT)%"
          http_filters:
          # 1. Callers cannot pre-set the identity tags or the proxy token.
          #    Runs before jwt_authn, which sets the identity headers below.
          - name: envoy.filters.http.header_mutation
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.header_mutation.v3.HeaderMutation
              mutations:
                request_mutations:
                - remove: x-headroom-proxy-token
                - remove: x-headroom-user
                - remove: x-headroom-principal
                - remove: x-headroom-app
          # 2. Entra access token from x-headroom-gateway-token. v2 and v1
          #    token formats are both accepted, so the registration's
          #    requestedAccessTokenVersion (shared with W.A.L.T.E.R.) never
          #    needs to change for this gateway.
          - name: envoy.filters.http.jwt_authn
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
              providers:
                entra_v2:
                  issuer: https://login.microsoftonline.com/__TENANT__/v2.0
                  audiences: [__CLIENT_ID__, __APP_ID_URI__]
                  from_headers: [{ name: x-headroom-gateway-token }]
                  forward: false
                  payload_in_metadata: entra
                  claim_to_headers:
                  - { header_name: x-headroom-user, claim_name: preferred_username }
                  - { header_name: x-headroom-principal, claim_name: oid }
                  - { header_name: x-headroom-app, claim_name: azp }
                  remote_jwks:
                    http_uri:
                      uri: https://__JWKS_HOST__:__JWKS_PORT__/__TENANT__/discovery/v2.0/keys
                      cluster: entra
                      timeout: 5s
                    cache_duration: 3600s
                    async_fetch: { fast_listener: false }
                    retry_policy: { num_retries: 3 }
                entra_v1:
                  issuer: https://sts.windows.net/__TENANT__/
                  audiences: [__CLIENT_ID__, __APP_ID_URI__]
                  from_headers: [{ name: x-headroom-gateway-token }]
                  forward: false
                  payload_in_metadata: entra
                  claim_to_headers:
                  - { header_name: x-headroom-user, claim_name: upn }
                  - { header_name: x-headroom-principal, claim_name: oid }
                  - { header_name: x-headroom-app, claim_name: appid }
                  remote_jwks:
                    http_uri:
                      uri: https://__JWKS_HOST__:__JWKS_PORT__/__TENANT__/discovery/keys
                      cluster: entra
                      timeout: 5s
                    cache_duration: 3600s
                    async_fetch: { fast_listener: false }
                    retry_policy: { num_retries: 3 }
              rules:
              # Claude Code's preconnect; Headroom exempts it from its own gate.
              - match: { path: /api/hello }
              - match: { prefix: /v1/ }
                requires: { requires_any: { requirements: [{ provider_name: entra_v2 }, { provider_name: entra_v1 }] } }
              - match: { prefix: /api/ }
                requires: { requires_any: { requirements: [{ provider_name: entra_v2 }, { provider_name: entra_v1 }] } }
          # 3. A valid token is not enough: the registration also signs in
          #    W.A.L.T.E.R.'s dashboard and connector. Only tokens carrying the
          #    Headroom scope (people) or app role (services) reach the API.
          - name: envoy.filters.http.rbac
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
              rules:
                action: ALLOW
                policies:
                  browser-routes:
                    permissions:
                    - not_rule:
                        or_rules:
                          rules:
                          - url_path: { path: { prefix: /v1/ } }
                          - url_path: { path: { prefix: /api/ } }
                    principals: [{ any: true }]
                  preconnect:
                    permissions: [{ url_path: { path: { exact: /api/hello } } }]
                    principals: [{ any: true }]
                  people:
                    permissions: [{ any: true }]
                    principals:
                    # scp is space-separated; RE2 matches the whole value.
                    - metadata:
                        filter: envoy.filters.http.jwt_authn
                        path: [{ key: entra }, { key: scp }]
                        value: { string_match: { safe_regex: { regex: "(.* )?__SCOPE__( .*)?" } } }
                  services:
                    permissions: [{ any: true }]
                    principals:
                    - metadata:
                        filter: envoy.filters.http.jwt_authn
                        path: [{ key: entra }, { key: roles }]
                        value: { list_match: { one_of: { string_match: { exact: __APP_ROLE__ } } } }
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
              suppress_envoy_headers: true
          route_config:
            name: gateway
            # Never let a caller-supplied value through, and never echo the token.
            request_headers_to_remove: [x-headroom-gateway-token]
            virtual_hosts:
            # The dashboard is served on its own hostname(s) only (and the app's
            # ACA FQDN, for tests). Any other name, e.g. headroom.powell-software.com
            # once it points here, gets the API routes only.
            - name: dashboard
              domains: [__DASHBOARD_DOMAINS__]
              routes:
              # Browser routes: GET only. FastAPI registers no HEAD for its
              # GET routes, so a HEAD would reach Headroom's passthrough relay.
              - match: { path: /, headers: [{ name: ":method", string_match: { exact: GET } }] }
                route: { cluster: headroom, prefix_rewrite: /dashboard, host_rewrite_literal: __UPSTREAM_HOST__ }
                request_headers_to_remove: [cookie, authorization]
                request_headers_to_add: &proxy_token
                - header: { key: x-headroom-proxy-token, value: "%ENVIRONMENT(HEADROOM_PROXY_TOKEN)%" }
                  append_action: OVERWRITE_IF_EXISTS_OR_ADD
              - match: { safe_regex: { regex: "/dashboard/?|/stats|/stats-history|/stats-lifetime|/health" }, headers: [{ name: ":method", string_match: { exact: GET } }] }
                route: { cluster: headroom, host_rewrite_literal: __UPSTREAM_HOST__ }
                request_headers_to_remove: [cookie, authorization]
                request_headers_to_add: *proxy_token
              - match: { prefix: /dashboard/static/, headers: [{ name: ":method", string_match: { exact: GET } }] }
                route: { cluster: headroom, host_rewrite_literal: __UPSTREAM_HOST__ }
                request_headers_to_remove: [cookie, authorization]
                request_headers_to_add: *proxy_token
              # API routes: any method, Authorization kept (Anthropic
              # credential), no timeout, no retries (POST bodies are never
              # replayed), streamed both ways.
              - match: { prefix: /v1/ }
                route: &api { cluster: headroom, host_rewrite_literal: __UPSTREAM_HOST__, timeout: 0s, idle_timeout: 900s }
                request_headers_to_remove: [cookie]
                request_headers_to_add: *proxy_token
              - match: { prefix: /api/ }
                route: *api
                request_headers_to_remove: [cookie]
                request_headers_to_add: *proxy_token
              - match: { prefix: / }
                direct_response: &not_found { status: 404, body: { inline_string: "not found\n" } }
            - name: api-only
              domains: ["*"]
              routes:
              - match: { prefix: /v1/ }
                route: *api
                request_headers_to_remove: [cookie]
                request_headers_to_add: *proxy_token
              - match: { prefix: /api/ }
                route: *api
                request_headers_to_remove: [cookie]
                request_headers_to_add: *proxy_token
              - match: { prefix: / }
                direct_response: *not_found

  clusters:
  - name: headroom
    type: STRICT_DNS
    connect_timeout: 5s
    load_assignment:
      cluster_name: headroom
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: __UPSTREAM_HOST__, port_value: __UPSTREAM_PORT__ } } }
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        common_http_protocol_options: { idle_timeout: 300s }
        explicit_http_config: { http_protocol_options: {} }
    circuit_breakers:
      thresholds: [{ max_connections: 4096, max_pending_requests: 4096, max_requests: 4096 }]
  - name: entra
    type: LOGICAL_DNS
    dns_lookup_family: V4_PREFERRED
    connect_timeout: 5s
    load_assignment:
      cluster_name: entra
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: __JWKS_HOST__, port_value: __JWKS_PORT__ } } }
    transport_socket:
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
        sni: __JWKS_HOST__
        common_tls_context:
          validation_context:
            trusted_ca: { filename: __CA_FILE__ }
            match_typed_subject_alt_names:
            - san_type: DNS
              matcher: { exact: __JWKS_HOST__ }
