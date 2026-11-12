# Makes lastgenre use a personal Last.fm API key instead of the shared one
# hardcoded in beets. Runs at import time because lastgenre builds its
# Last.fm client when its module is imported.
# Also makes lastgenre skip any album or track flagged lastgenre_skip.
# Also blocks every file write (write, modify, import, lastgenre) for items
# flagged lastgenre_skip; the database still updates, the file does not.
import sys
from importlib import import_module

from beets import config, plugins
from beets.library import WriteError
from beets.plugins import BeetsPlugin

# keyfile can be changed with lastfmkey: {keyfile: <path>}
keyfile = config["lastfmkey"]["keyfile"].get("/config/lastfm-key.txt")

try:
    with open(keyfile) as f:
        key = f.read().strip()
except OSError:
    key = ""

if key:
    plugins.LASTFM_KEY = key
    # if lastgenre was imported first, patch its existing client too
    client = sys.modules.get("beetsplug.lastgenre.client")
    if client is not None:
        client.LASTFM.api_key = key
else:
    plugins.log.warning(
        "lastfmkey: no key in {}, using the shared Last.fm key", keyfile
    )


# lastgenre_skip: set on albums and their items to keep lastgenre from
# touching them (it would write tags from blank DB values). The original
# _process is a singledispatchmethod, so keep the descriptor and call it
# through __get__.
_FALSY = ("", "0", "false", "no")


def _skip_flagged(obj):
    values = [obj.get("lastgenre_skip")]
    if hasattr(obj, "get_album"):
        album = obj.get_album()
        if album is not None:
            values.append(album.get("lastgenre_skip"))
    for value in values:
        if value and str(value).strip().lower() not in _FALSY:
            return True
    return False


def patch_lastgenre():
    # patch only once, whatever the plugin load order
    try:
        module = sys.modules.get("beetsplug.lastgenre") or import_module(
            "beetsplug.lastgenre"
        )
    except ImportError:
        return
    cls = module.LastGenrePlugin
    original = cls.__dict__["_process"]
    if getattr(original, "_lastgenre_skip_patched", False):
        return

    def _process(self, obj, write):
        if _skip_flagged(obj):
            self._log.info("skipping {} (lastgenre_skip)", obj)
            return
        return original.__get__(self, type(self))(obj, write)

    _process._lastgenre_skip_patched = True
    cls._process = _process


# if lastgenre was imported first, patch it now
if "beetsplug.lastgenre" in sys.modules:
    patch_lastgenre()


# 'write' is sent before the file is opened. Raising a WriteError from the
# listener makes Item.try_write log an error and return, file untouched.
def _block_flagged_write(item, path, tags, **kwargs):
    if _skip_flagged(item):
        raise WriteError(
            path, Exception("write blocked: lastgenre_skip is set (blank DB values)")
        )


class LastfmKeyPlugin(BeetsPlugin):
    def __init__(self):
        super().__init__()
        patch_lastgenre()
        self.register_listener("pluginload", patch_lastgenre)
        self.register_listener("write", _block_flagged_write)
    pass
