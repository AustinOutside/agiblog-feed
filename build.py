#!/usr/bin/env python3
"""Build feeds.json for agi.blog.

Fetches every RSS/Atom source below, keeps the newest items, strips all HTML,
keeps only http/https links, and writes public/feeds.json in an
rss2json-compatible shape keyed by source name:

  {"generated": "...", "feeds": {"TechCrunch AI": {"status": "ok", "items": [...]}, ...}}

Each source keeps at most MAX_ITEMS items (SOURCE_CAPS overrides that).
Before writing, a later item is dropped when its normalized link or title
matches an item already seen from an earlier source. First-listed sources win.

Standard library only. One failing source never breaks the others.
"""
import concurrent.futures, datetime, email.utils, html, json, os, re, sys, urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# name must match the `name:` in the agi.blog code block FEEDS list.
FEEDS = [
    ("TechCrunch AI",   "https://techcrunch.com/category/artificial-intelligence/feed/"),
    ("The Verge AI",    "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml"),
    ("VentureBeat AI",  "https://feeds.feedburner.com/venturebeat/SZYF"),
    ("Wired AI",        "https://www.wired.com/feed/tag/ai/latest/rss"),
    ("Ars Technica AI", "https://arstechnica.com/ai/feed"),
    ("MIT Tech Review", "https://www.technologyreview.com/feed/"),
    ("MIT News AI",     "https://news.mit.edu/rss/topic/artificial-intelligence2"),
    ("ArXiv AI",        "https://rss.arxiv.org/rss/cs.AI"),
    ("ArXiv ML",        "https://export.arxiv.org/api/query?search_query=cat:cs.LG&sortBy=submittedDate&sortOrder=descending&max_results=20"),
    ("OpenAI",          "https://openai.com/news/rss.xml"),
    ("Anthropic",       "https://raw.githubusercontent.com/taobojlen/anthropic-rss-feed/main/anthropic_news_rss.xml"),
    ("Google DeepMind", "https://deepmind.google/blog/rss.xml"),
    ("Google AI Blog",  "https://blog.google/technology/ai/rss"),
    ("Stability AI",    "https://stability.ai/news-updates?format=rss"),
    ("Hacker News",     "https://hnrss.org/newest?q=AI+OR+LLM+OR+%22artificial+intelligence%22&count=20"),
    ("Hacker Noon AI",  "https://hackernoon.com/tagged/ai/feed"),
    ("Product Hunt AI", "https://www.producthunt.com/feed?category=artificial-intelligence"),
    ("AI Supremacy",    "https://www.ai-supremacy.com/feed"),
    ("Understanding AI","https://www.understandingai.org/feed"),
    ("Hugging Face",    "https://huggingface.co/blog/feed.xml"),
    ("Microsoft AI",    "https://news.microsoft.com/source/topics/ai/feed/"),
    ("NVIDIA AI",       "https://developer.nvidia.com/blog/feed"),
    ("Apple ML",        "https://machinelearning.apple.com/rss.xml"),
    # Technical / research additions (2026-10-29)
    ("Anthropic Research", "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_research.xml"),
    ("Google Research", "https://research.google/blog/rss/"),
    ("Microsoft Research", "https://www.microsoft.com/en-us/research/feed/"),
    ("Ai2",             "https://allenai.org/rss.xml"),
    ("Mistral AI",      "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_mistral.xml"),
    ("Epoch AI",        "https://epoch.ai/atom.xml"),
    ("Simon Willison",  "https://simonwillison.net/tags/llms.atom"),
    ("Interconnects",   "https://www.interconnects.ai/feed"),
    ("Latent Space",    "https://www.latent.space/feed"),
    ("Import AI",       "https://importai.substack.com/feed"),
]
MAX_ITEMS = 20
# These two post often enough to crowd a date-sorted page.
SOURCE_CAPS = {
    "Latent Space": 8,
    "Simon Willison": 8,
}
# Query keys that do not identify the article. utm_* and hsa_* match by prefix.
TRACKING_PARAMS = frozenset({
    "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid",
    "msclkid", "twclid", "li_fat_id", "ttclid", "yclid", "srsltid",
    "mc_cid", "mc_eid", "mkt_tok", "igshid", "igsh",
    "_ga", "_gl", "_hsenc", "_hsmi",
    "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv",
    "ncid", "ref", "ref_src",
})
_missing_caps = sorted(set(SOURCE_CAPS) - {name for name, _url in FEEDS})
if _missing_caps:
    raise SystemExit("SOURCE_CAPS names missing from FEEDS: " + ", ".join(_missing_caps))
UA = "Mozilla/5.0 (compatible; agi.blog feed builder; +https://www.agi.blog)"
OUT = os.environ.get("OUT_DIR", "public")


def local(tag):
    return tag.rsplit("}", 1)[-1].lower()


def child(el, *names):
    for c in el:
        if local(c.tag) in names:
            return c
    return None


def text_of(el):
    return "".join(el.itertext()).strip() if el is not None else ""


def plain(s, limit):
    s = html.unescape(re.sub(r"<[^>]*>", " ", s or ""))
    s = re.sub(r"<[^>]*>", " ", s)          # second pass for escaped markup
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def iso(s):
    s = (s or "").strip()
    if not s:
        return ""
    try:
        d = email.utils.parsedate_to_datetime(s)
    except (TypeError, ValueError):
        try:
            d = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError:
            return ""
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_link(u):
    u = (u or "").strip()
    return u if re.match(r"^https?://", u, re.I) else ""


def parse(xml_bytes, limit=MAX_ITEMS):
    xml_bytes = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", xml_bytes)
    root = ET.fromstring(xml_bytes)
    items = []
    for el in root.iter():
        kind = local(el.tag)
        if kind not in ("item", "entry"):
            continue
        title = plain(text_of(child(el, "title")), 300)
        link = ""
        if kind == "entry":
            for c in el:
                if local(c.tag) == "link" and c.get("rel", "alternate") == "alternate" and c.get("href"):
                    link = c.get("href"); break
        if not link:
            l = child(el, "link")
            link = (l.get("href") if l is not None and l.get("href") else text_of(l))
        if not link:
            g = child(el, "guid", "id")
            link = text_of(g)
        desc = text_of(child(el, "description", "summary", "encoded", "content"))
        date = text_of(child(el, "pubdate", "published", "updated", "date", "issued"))
        link = safe_link(link)
        if title and link:
            items.append({"title": title, "link": link, "description": plain(desc, 400), "pubDate": iso(date)})
    items.sort(key=lambda i: i["pubDate"], reverse=True)
    return items[:limit]


def normalize_link(url):
    """Lowercase the host, drop the fragment, the trailing slash, and tracking params."""
    raw = (url or "").strip()
    try:
        parts = urlsplit(raw)
    except ValueError:
        return raw
    host = (parts.hostname or "").lower()
    if not host:
        return raw
    netloc = f"{host}:{parts.port}" if parts.port else host
    kept = []
    for key, value in parse_qsl(parts.query, keep_blank_values=True):
        lk = key.lower()
        if lk.startswith("utm_") or lk.startswith("hsa_") or lk in TRACKING_PARAMS:
            continue
        kept.append((key, value))
    kept.sort()
    return urlunsplit((parts.scheme.lower(), netloc, parts.path.rstrip("/"), urlencode(kept), ""))


def normalize_title(title):
    """Lowercase, then collapse punctuation and whitespace."""
    s = (title or "").lower()
    s = re.sub(r"[^\w\s]+", " ", s)
    s = s.replace("_", " ")
    return re.sub(r"\s+", " ", s).strip()


def dedupe(results):
    """Drop later items whose link or title matches an earlier one. Returns the drop count.

    Sources are walked in FEEDS order, so the first-listed source keeps the item.
    """
    seen_links = set()
    seen_titles = set()
    dropped = 0
    for name, _url in FEEDS:
        entry = results.get(name) or {}
        kept = []
        for item in entry.get("items") or []:
            link_key = normalize_link(item.get("link", ""))
            title_key = normalize_title(item.get("title", ""))
            if (link_key and link_key in seen_links) or (title_key and title_key in seen_titles):
                dropped += 1
            else:
                kept.append(item)
            if link_key:
                seen_links.add(link_key)
            if title_key:
                seen_titles.add(title_key)
        if "items" in entry:
            entry["items"] = kept
    return dropped


def fetch(name_url):
    name, url = name_url
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"})
        with urllib.request.urlopen(req, timeout=30) as r:
            items = parse(r.read(), SOURCE_CAPS.get(name, MAX_ITEMS))
        if not items:
            return name, {"status": "error", "message": "no items", "items": []}
        return name, {"status": "ok", "items": items}
    except Exception as e:  # isolate every source
        return name, {"status": "error", "message": f"{type(e).__name__}: {e}"[:200], "items": []}


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = dict(ex.map(fetch, FEEDS))
    ok = sum(1 for v in results.values() if v["status"] == "ok")
    out = {
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ok": ok, "total": len(FEEDS),
        "feeds": results,
    }
    # Keep last good data for a source that failed this run.
    prev_path = os.path.join(OUT, "feeds.json")
    prev_url = os.environ.get("PREVIOUS_URL")
    prev = None
    try:
        if prev_url:
            with urllib.request.urlopen(urllib.request.Request(prev_url, headers={"User-Agent": UA}), timeout=20) as r:
                prev = json.load(r)
        elif os.path.exists(prev_path):
            prev = json.load(open(prev_path))
    except Exception:
        prev = None
    if prev:
        for name, v in results.items():
            pv = prev.get("feeds", {}).get(name)
            if v["status"] != "ok" and pv and pv.get("status") == "ok":
                results[name] = dict(pv, stale=True)
    dropped = dedupe(results)
    os.makedirs(OUT, exist_ok=True)
    with open(prev_path, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write("<!doctype html><title>agi.blog feed data</title><p>Data for <a href=\"https://www.agi.blog\">agi.blog</a>: <a href=\"feeds.json\">feeds.json</a></p>")
    for name, v in results.items():
        print(f"{v['status']:6} {len(v['items']):3}  {name}  {v.get('message','')}")
    print(f"{ok}/{len(FEEDS)} sources ok, deduped {dropped} items")
    if ok == 0:
        sys.exit(1)  # do not deploy an empty file


if __name__ == "__main__":
    main()
