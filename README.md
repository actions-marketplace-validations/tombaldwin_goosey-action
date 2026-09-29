# goosey social card check

A GitHub Action that fails a build when a page's social card is broken: the preview a link gets
when it is shared on LinkedIn, X, Slack, Facebook or WhatsApp. It checks each page's Open Graph and
Twitter card tags, and fetches the image to confirm it loads and is a usable size and shape.

It is the CI half of [goosey](https://goosey.poly.io/), and it applies the levels you set there
the same way goosey does. The checking is done by the
[Open Graph API](https://www.poly.io/social-card-preview/api/) at `api.poly.io/og`. The action
itself is bash, curl and jq, which every GitHub-hosted runner already has, so there is nothing to
install or build.

## Usage

Check a few pages on every pull request:

```yaml
on: pull_request

jobs:
  cards:
    runs-on: ubuntu-latest
    steps:
      - uses: tombaldwin/goosey-action@v1
        with:
          urls: |
            https://www.example.com/
            https://www.example.com/pricing/
            https://www.example.com/blog/latest-post/
```

Check a whole site every morning, one or more pages per template:

```yaml
on:
  schedule:
    - cron: "0 6 * * *"

jobs:
  cards:
    runs-on: ubuntu-latest
    steps:
      - uses: tombaldwin/goosey-action@v1
        with:
          site: https://www.example.com
          key: ${{ secrets.OG_KEY }}
          levels: '{"image.webp":"ignore","author.missing":"error"}'
```

The API checks pages at their public addresses, so a pull request's changes are only seen once
they are deployed somewhere it can reach. On a preview deployment, pass the preview's URLs.

## What it does

1. With `site`, it asks the API for a plan. The API reads the site's sitemap, groups the URLs by
   shape, and picks pages from each group, because pages built from one template share one card
   bug. The plan is at most `cap` pages, and the summary says how many pages of the sitemap went
   unchecked.
2. It checks each page in `urls` and in the plan, once each, about 0.4 seconds apart, because the
   API's burst limit is shared by everyone who calls it.
3. It applies your `levels`, then fails the step if any page has a finding at `fail-on` or worse,
   or if a page could not be checked and `fail-on-unreachable` is true.

## Inputs

| Input | Default | Description |
|---|---|---|
| `urls` | | Pages to check, one per line. Blank lines and lines starting with `#` are skipped. |
| `site` | | An origin such as `https://example.com`. The API picks the pages from its sitemap. |
| `cap` | `40` | With `site`, the most pages the plan may pick, from 1 to 100. Planning is one call and each page is one more. |
| `fail-on` | `error` | `error` or `warn`: the level, after your levels, that fails the step. |
| `levels` | | Your levels as JSON: check id to `ignore`, `tip`, `warn` or `error`. See below. |
| `fail-on-unreachable` | `true` | Whether a page the API could not check fails the step. A spent allowance only warns. |
| `key` | | An API key, sent as the `x-og-key` header. Pass it from a secret. |
| `contact` | | An email address or URL, sent as the `x-og-contact` header. Raises the anonymous allowance to 2,000 a day. |

At least one of `urls` and `site` is required. With both, the pages are checked together.

## Outputs

| Output | Description |
|---|---|
| `errors` | Findings at `error`, after levels, across every page checked. |
| `warnings` | Findings at `warn`, after levels, across every page checked. |
| `pages` | Pages the run set out to check, including any it could not. |
| `failed-pages` | Pages that failed the gate. |

The job summary has one line per page with its worst level, then every finding, each linked to a
reference page that says when it is raised and how to fix it. Errors and warnings are also posted as
annotations. GitHub shows at most ten of each per step, so the summary is the complete list.

## Levels

Every check has an id, such as `image.missing` or `description.long`, and the API gives each a
level: `error`, `warn`, `tip`, or `ok` for a pass. Those levels are defaults. A WebP image might be
something you shipped on purpose, and a missing author tag might matter a great deal to you. So any
check you have a view on can be given your own level, and anything you leave alone keeps the API's.

Copy your levels from goosey. goosey keeps them in your browser, under the `goosey.policy` key in
local storage, in exactly the shape this input takes:

```json
{"image.webp": "ignore", "author.missing": "error"}
```

The rules are goosey's:

- `error` raises a check to an error. `warn`, `tip` and `ignore` move it below one. `ignore` also
  leaves it out of the summary, which counts it instead.
- A check the API passed stays passed. Setting `title.ok` to `error` does nothing, since there is
  nothing wrong to re-level.
- A value that is not one of the four levels is dropped, as goosey drops it, and the step warns you
  so a typo does not quietly change the gate.

With `fail-on: error` the action passes and fails exactly the pages that goosey's own "Gate a
build on this" snippet would. `fail-on: warn` goes further, and a new check could then fail your
build: the API adds new checks at `warn` or `tip`, never at `error`, and logs each one in its
[change log](https://www.poly.io/social-card-preview/api/#changes).

## Pages that could not be checked

A page the API could not check is its own outcome, not a pass. The page may return a 404, or its
host may not resolve. By default it fails the step, because a gate that goes green without looking
is worse than none. Set `fail-on-unreachable: false` to report it as a warning instead.

A spent daily allowance is different: it says nothing about the change under review, so it only
warns, and so do the pages the run could not reach because of it.

The run stops early, and says so once, when every further call would be refused the same way: the
daily allowance is spent, the key is not accepted, or the API is refusing calls (HTTP 429 from the
shared burst limit, or a 5xx). A 429 or 5xx is retried once after a short wait, and no more. The
pages the run did not reach are listed as not checked. A key the API does not accept always fails
the step, whatever `fail-on-unreachable` says, because that is a fault in the workflow.

## Allowance and keys

Anonymous calls get 500 a day, counted per network address. A GitHub-hosted runner's address is
shared with other people's jobs, so on a busy day an anonymous run can find the allowance already
spent. A [free key](https://www.poly.io/social-card-preview/api/#key) raises it to 5,000 a day and
counts it against the key, whichever runner the job lands on.

Without a key, a `contact` input (an email address or a URL) raises the anonymous allowance to 2,000
a day, so that someone can reach you if a job misbehaves. It is kept in the API's logs for 90 days.

Store the key as a repository secret and pass it in:

```yaml
        with:
          key: ${{ secrets.OG_KEY }}
```

The key is sent only in the `x-og-key` header, never in a URL, and is masked in the log. A site
scan costs one call for the plan and one per page. Repeat checks of the same URL within about five
minutes are answered from the API's cache.

## Privacy

The API fetches each page and its preview images from their public addresses, measures them in
memory, and discards them when the check is done. It stores no page content and no images. Its logs
record which site was asked about, whether the check worked and the usage counts, and they are
deleted after 90 days. The full statement is at
[poly.io/privacy](https://www.poly.io/privacy/).

## Testing it locally

```sh
test/run.sh
```

runs the gate against recorded API answers, with curl replaced by a stand-in, so it needs no
network. `lib/judge.sh` judges one live answer read on stdin:

```sh
curl -s 'https://api.poly.io/og?url=https%3A%2F%2Fexample.com' | lib/judge.sh https://example.com
```

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
