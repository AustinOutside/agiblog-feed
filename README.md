# agiblog-feed

Builds `feeds.json` for https://www.agi.blog every 30 minutes with GitHub Actions and serves it from GitHub Pages.
The agi.blog code block fetches that single file instead of calling api.rss2json.com 23 times per visitor.

## One-time setup (Austin's GitHub account, free)
1. Create a new **public** repo named `agiblog-feed` (public repos get free Actions minutes and free Pages).
2. Push these files (`build.py`, `.github/workflows/build.yml`, `README.md`).
3. Repo Settings > Pages > Build and deployment > Source: **GitHub Actions**.
4. Actions tab > "Build agi.blog feeds" > Run workflow (first run). It also runs on every push.
5. Check `https://<github-username>.github.io/agiblog-feed/feeds.json` loads.
6. Apply the code block edits in `../agiblog-feed-edits.md`, using that URL.

## Notes
- Sources are listed in `build.py` (`FEEDS`). Names must match the `name:` values in the code block.
- A source that fails keeps its last good items (marked `"stale": true`) so one outage never blanks the page.
- If every source fails, the run fails and the previous good file stays live.
- GitHub disables scheduled workflows after 60 days with no repo activity; the workflow makes a one-line keepalive commit about once a week (when keepalive.txt is older than 7 days).
- GitHub Pages sends `Access-Control-Allow-Origin: *`, so the browser can read the file from agi.blog.
- Cost: $0 (public repo). Uses about 1 minute per run, about 1,500 minutes a month, all free on public repos.
