"""Applied after the original apps.gateway.mgmt module is loaded.
No new privileged identity is created. Existing bootstrap authorization and
single-use proof are executed first and are not changed. Only an already
present, user-local launcher cache is refreshed with that same session.
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
            if isinstance(result, dict) and isinstance(result.get('console_key'), str):
                try:
                    from product_launch import key_file, _store_key
                    # A browser cannot create a native launcher cache this way.
                    # The file must already have been established by the local launcher.
                    if key_file().is_file():
                        _store_key(result['console_key'])
                except Exception:
                    log.warning('Existing launcher session cache could not be refreshed; no credentials logged')
            return result
        route.dependant.call = claim_and_refresh_existing_launcher
    return router
