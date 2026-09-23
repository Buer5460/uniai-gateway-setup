"""Applied after the original apps.gateway.mgmt module is loaded.
No new privileged identity is created. The original single-use bootstrap
proof and all original authorization checks execute first, unchanged.
"""
_original_register = register

def register(*args, **kwargs):
    router = _original_register(*args, **kwargs)
    for route in router.routes:
        if getattr(route, 'path', '') != '/api/bootstrap' or 'POST' not in getattr(route, 'methods', set()):
            continue
        original_call = route.dependant.call
        async def claim_and_refresh_existing_launcher(request, _call=original_call):
            result = await _call(request)
            if getattr(result, 'status_code', 0) == 200:
                try:
                    import json as _json
                    body = _json.loads(result.body)
                    if body.get('role') == 'admin' and isinstance(body.get('console_key'), str):
                        from product_launch import key_file, _store_key
                        # The browser does not create a persistent identity. Refresh
                        # only a cache already established by the native launcher.
                        if key_file().is_file():
                            _store_key(body['console_key'])
                except Exception:
                    log.warning('Existing launcher cache refresh failed; credentials were not logged')
            return result
        route.dependant.call = claim_and_refresh_existing_launcher
    return router
