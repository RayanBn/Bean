# Browser page

When a browser is in front, Bean knows the active tab of the focused window: its URL, host and title, and the search the user is doing (a Google, DuckDuckGo, Bing or GitHub search query, or a Stack Overflow question title). It reads this through Accessibility only, never page text and never other tabs. On a mail site (Gmail, Outlook, Proton, iCloud Mail, Yahoo, Fastmail) it reads nothing.

## Sub-features

- `browser-page`: Arc, Safari and Chrome give `url`, `host` and `title` of the active tab.
- `browser-search`: a search results page gives `isSearch:true` and the decoded `searchQuery`. A Stack Overflow question gives its title as `searchQuery`.
- `browser-mail`: a mail tab gives `nil`.
- `browser-speed`: one read takes under 100 ms.

## How to get to it (user POV)

- Use Arc, Safari or Chrome. Bean reads the tab in front.
- For a check without the notch, `bean probe-browser [bundle-id]` reads the browser named, or the frontmost app when no bundle id is given. It needs no notch lock, and prints the timing of 20 reads and the page as JSON.

## Driving it with bean

Preconditions:

- `bean build` succeeded. The launching process has Accessibility.
- The user is not in a call in that browser. Opening tabs brings the browser to the front.

- **Search.** Run `open -a Arc "https://www.google.com/search?q=TypeError%3A+Cannot+read+properties+of+undefined+%28reading+%27map%27%29"`, wait 4 s, then `bean probe-browser company.thebrowser.Browser`. Expect `"isSearch":true` and `"searchQuery":"TypeError: Cannot read properties of undefined (reading 'map')"`.
- **GitHub page.** Open `https://github.com/ggml-org/llama.cpp` the same way. Expect `"host":"github.com"`, `"isSearch":false` and the repository title. `https://github.com/search?q=AXWebArea+AXURL&type=code` gives `"searchQuery":"AXWebArea AXURL"`.
- **Stack Overflow.** `https://stackoverflow.com/questions/1642028/what-is-the-operator-in-c-c` gives `"searchQuery":"What is the '-->' operator in C/C++?"`.
- **Mail.** Open `https://mail.google.com/mail/u/0/`. `bean probe-browser company.thebrowser.Browser` prints `nil`.
- **Safari.** `open -a Safari <url>`, then `bean probe-browser com.apple.Safari`. Same fields.
- **Speed.** Every probe line has `median` and `max` under 100 ms.
- **Proof.** The probe lines are appended to `artifacts/verify/$BEAN_RUN_ID/probe-browser.txt`. Close the tabs you opened.

## Gotchas

- Without a bundle id the probe reads the frontmost app, which is the terminal or Claude by the time it runs. Pass the bundle id.
- Chrome was not installed when this was written. Its path, through the web area or the address bar, is unverified.
- Never screenshot a mail tab: the reader returns nil, a screenshot would not.
- A tab that is still loading can give the previous URL. Wait for the page.
