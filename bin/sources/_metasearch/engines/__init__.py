from . import ddg_lite, bing, ecosia, startpage, brave

PAGE_FETCHERS = {
    "ddg_lite":  ddg_lite.scrape,
    "bing":      bing.scrape,
    "ecosia":    ecosia.scrape,
    "startpage": startpage.scrape,
    "brave":     brave.scrape,
}
MULTI_STEP = {}
ALL_ENGINES = {**PAGE_FETCHERS, **MULTI_STEP}

SINGLE_PAGE = frozenset(
    e for mod in [brave] for e in [mod.NAME] if getattr(mod, "SINGLE_PAGE", False)
)
EXPERIMENTAL = frozenset()
RELIABLE = frozenset(ALL_ENGINES.keys()) - EXPERIMENTAL
DEFAULT = frozenset(["ddg_lite", "bing", "ecosia", "startpage", "brave"])
