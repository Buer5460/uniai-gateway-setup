"""Refresh only a pre-existing local launcher cache after the original
bootstrap handler authorizes a successful single-use proof. Original
privilege checks and response are preserved; no new identity is created.
"""
_original_register = register

def register(*args, **kwargs):
    import functools as _functools
    router = _original_register(*args, **kwargs)
    def wrap(original):
        @_functools.wraps(original)
        async def claim_and_refresh_existing_launcher(*call_args, **call_kwargs):
            result = await original(*call_args, **call_kwargs)
            if getattr(result, 'status_code', 0) == 200:
                try:
                    import json as _json
                    body = _json.loads(result.body)
                    if body.get('role') == 'admin' and isinstance(body.get('console_key'), str):
                        from product_launch import key_file, _store_key
                        if key_file().is_file():
                            _store_key(body['console_key'])
                except Exception:
                    log.warning('Existing launcher cache refresh failed; credentials were not logged')
            return result
        return claim_and_refresh_existing_launcher
    for route in router.routes:
        if getattr(route, 'path', '') != '/api/bootstrap' or 'POST' not in getattr(route, 'methods', set()):
            continue
        callback = wrap(route.endpoint)
        # include_router reconstructs APIRoute from endpoint; changing only
        # dependant.call would be lost at that later copy step.
        route.endpoint = callback
        route.dependant.call = callback
    return router
