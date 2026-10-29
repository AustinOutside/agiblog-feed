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
- GitHub was dropping the `*/30` schedule (runs landed every 4–6 hours, and each one started immediately). After each publish, `.github/workflows/build.yml` waits until the file is about 30 minutes old and dispatches the next run with the built-in token. No extra secret. Crons at minutes 7, 19, 37, and 49 only restart that chain if a run dies. Run workflow, and pushes to `main`, still build immediately.
- GitHub Pages sends `Access-Control-Allow-Origin: *`, so the browser can read the file from agi.blog.
- Cost: $0 (public repo). Publishing takes about a minute; the half-hour wait holds one runner between publishes. Actions minutes on public repos are not billed.
