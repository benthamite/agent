"""Tests for the Markdown renderer in the phone page, in headless Chromium."""
import random
import re
import unittest
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None

PAGE = Path(__file__).resolve().parents[2] / "etc/agent-remote.html"
TOKEN = "[REDACTED:github-token:d47c5563]"


@unittest.skipIf(sync_playwright is None, "playwright is not installed")
class RemoteMarkdownTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)
        cls.page = cls.open_page()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    @classmethod
    def open_page(cls):
        page = cls.browser.new_context(viewport={"width": 390, "height": 780}).new_page()
        page.route("**/api/**", lambda route: route.fulfill(
            json={"sessions": []}))
        page.route("http://phone.test/", lambda route: route.fulfill(
            body=PAGE.read_text(encoding="utf-8"), content_type="text/html"))
        page.goto("http://phone.test/")
        page.evaluate("""() => { window.show = (text, parent) => {
          const box = document.createElement("div");
          box.className = "msg assistant";
          box.append(renderMarkdown(text));
          (parent || document.getElementById("list")).replaceChildren(box);
          return box; }; }""")
        return page

    def render(self, text, page=None):
        """Return the rendered HTML of TEXT, which holds its own escaping."""
        return (page or self.page).evaluate("(t) => show(t).innerHTML", text)

    def text(self, text):
        return self.page.evaluate("(t) => show(t).textContent", text)

    def tags(self, text):
        return self.page.evaluate(
            "(t) => [...show(t).querySelectorAll('*')].map(e => e.tagName)", text)

    def test_inline(self):
        html = self.render("a **bold** *it* `co*de*` _und_ \\*lit\\*")
        self.assertIn("<strong>bold</strong>", html)
        self.assertIn("<em>it</em>", html)
        self.assertIn("<code>co*de*</code>", html)
        self.assertIn("<em>und</em>", html)
        self.assertIn("*lit*", html)

    def test_code_is_not_parsed_further(self):
        self.assertIn("<code>**x** [a](http://b.c)</code>",
                      self.render("`**x** [a](http://b.c)`"))
        html = self.render("```python\n**x** <b>\n| a | b |\n|---|---|\n```\nafter")
        self.assertIn("**x** &lt;b&gt;\n| a | b |\n|---|---|", html)
        self.assertNotIn("<strong>", html)
        self.assertNotIn("<table>", html)
        self.assertIn("python", html)
        self.assertIn("<p>after</p>", html)
        self.assertIn("<strong>a `**` b</strong>".replace("`**`", "<code>**</code>"),
                      self.render("**a `**` b**"))

    def test_blocks(self):
        html = self.render("# One\n### Three\n\n> quoted **b**\n\n---\n\npara\nline")
        self.assertIn("<h3>One</h3>", html)
        self.assertIn("<h5>Three</h5>", html)
        self.assertIn("<blockquote><p>quoted <strong>b</strong></p></blockquote>", html)
        self.assertIn("<hr>", html)
        self.assertIn("<p>para\nline</p>", html)

    def test_lists(self):
        html = self.render("- a\n  - nested\n- b\n\n3. three\n4. four\n   more\n\n   para")
        self.assertIn("<ul><li><p>a</p><ul><li><p>nested</p></li></ul></li><li><p>b</p></li></ul>", html)
        self.assertIn('<ol start="3">', html)
        self.assertIn("<p>four\nmore</p><p>para</p>", html)
        self.assertEqual(self.tags("* * *"), ["HR"])
        self.assertEqual(self.tags("**bold** start"), ["P", "STRONG"])

    def test_table(self):
        html = self.render("| a | `x|y` |\n|:--|--:|\n| **1** | 2 \\| 3 |\n| 4 | 5 | extra |\nafter")
        self.assertIn("<th>a</th>", html.replace(' style="text-align: left;"', ""))
        self.assertIn("<code>x|y</code>", html)
        self.assertIn("<strong>1</strong>", html)
        self.assertIn("2 | 3", html)
        self.assertIn("extra", html)
        self.assertIn('text-align: right', html)
        self.assertIn("<p>after</p>", html)
        self.assertNotIn("<table>", self.render("a | b\nnot a rule"))
        self.assertNotIn("<table>", self.render("a | b\n|---|---|---|"))

    def test_wide_content_scrolls_by_itself(self):
        long_cell = "wide" * 40
        result = self.page.evaluate("""([code, table]) => {
          const box = show(code + "\\n\\n" + table);
          const list = document.getElementById("list");
          const scrollers = [...box.querySelectorAll(".md-scroll")];
          return { pageFits: document.documentElement.scrollWidth <= 390
                     && list.scrollWidth <= list.clientWidth,
                   scroll: scrollers.map(e => [e.clientWidth <= 390,
                                               e.scrollWidth > e.clientWidth]) };
        }""", ["```\n" + long_cell + "\n```",
               "| " + " | ".join(["column heading"] * 12) + " |\n|"
               + "---|" * 12 + "\n| " + " | ".join(["cell text"] * 12) + " |"])
        self.assertTrue(result["pageFits"])
        self.assertEqual(result["scroll"], [[True, True], [True, True]])

    def test_links(self):
        html = self.render("[a *b*](https://x.org/p_q_r?a=1&b=2) http://y.org/z_w. <https://v.org>")
        self.assertIn('href="https://x.org/p_q_r?a=1&amp;b=2"', html)
        self.assertIn("a <em>b</em></a>", html)
        self.assertIn('href="http://y.org/z_w"', html)
        self.assertIn('href="https://v.org/"', html)
        self.assertIn('rel="noopener noreferrer"', html)
        self.assertIn('href="https://w.org/a_(b)"', self.render("(see https://w.org/a_(b))"))

    def test_only_http_links(self):
        for bad in ["[x](javascript:alert(1))", "[x](JaVaScRiPt:alert(1))",
                    "[x](data:text/html,<script>alert(1)</script>)",
                    "[x](file:///etc/passwd)", "[x](vbscript:y)", "[x](/relative)",
                    "[x](ftp://a.b)", "[x](//a.b)", "<javascript:alert(1)>",
                    "javascript:alert(1)", "[x](java\tscript:alert(1))",
                    "[x](http://)", "[x]( javascript:alert(1))"]:
            with self.subTest(bad):
                self.assertEqual(self.text(bad), bad)
                self.assertEqual(self.tags(bad), ["P"])

    def test_markup_stays_text(self):
        for bad in ["<img src=x onerror=\"window.pwned=1\">",
                    "<script>window.pwned=1</script>",
                    "<svg onload=window.pwned=1>", "<a href=\"javascript:x\">y</a>",
                    "<iframe src=javascript:window.pwned=1></iframe>",
                    "**<img src=x onerror=window.pwned=1>**",
                    "| <img src=x onerror=window.pwned=1> |\n|---|\n| b |",
                    "```<img src=x onerror=window.pwned=1>\nx\n```",
                    "[<img src=x onerror=window.pwned=1>](https://a.b)",
                    "[a](https://a.b/\"onmouseover=\"window.pwned=1)"]:
            with self.subTest(bad):
                tags = self.tags(bad)
                for tag in ("IMG", "SCRIPT", "SVG", "IFRAME"):
                    self.assertNotIn(tag, tags)
                self.assertFalse(self.page.evaluate(
                    "[...document.querySelectorAll('#list a')]"
                    ".some(a => a.getAttributeNames().some(n => n.startsWith('on'))"
                    " || !/^https?:/.test(a.href))"))
        self.page.wait_for_timeout(100)
        self.assertFalse(self.page.evaluate("!!window.pwned"))

    def test_unbalanced_markers_stay_readable(self):
        for text in ["**open", "close**", "*a", "_a", "`open", "``open`", "[open",
                     "[a](https://b.c", "2 * 3 * 4", "snake_case_name", "*.el and *.py",
                     "> ", "|", "| a", "#nohash", "****a", "a\\"]:
            with self.subTest(text):
                self.assertEqual(self.text(text).strip(), text.lstrip("> ").strip())
        self.assertEqual(self.tags("snake_case_name and __init__.py")[0], "P")
        self.assertIn("rest of it", self.text("```\nnever closed\nrest of it"))

    def test_redaction_placeholders_survive(self):
        for text in [TOKEN, "**" + TOKEN + "**", "`" + TOKEN + "`",
                     "```\n" + TOKEN + "\n```", "| " + TOKEN + " |\n|---|\n| " + TOKEN + " |",
                     "[" + TOKEN + "](https://a.b)", "- " + TOKEN, "> " + TOKEN, "# " + TOKEN]:
            with self.subTest(text):
                self.assertIn(TOKEN, self.text(text))
        html = self.render("[x](https://user:" + TOKEN + "@host.org/)")
        self.assertIn("REDACTED", html)

    def test_no_text_is_lost(self):
        """Random mixes of markers keep every word, in order."""
        rng = random.Random(7)
        pieces = ["**", "*", "_", "__", "`", "``", "```\n", "[", "]", "(", ")", "\n", "\n\n",
                  "> ", "- ", "# ", "|", "|---|\n", "<", ">", " ", "\\", "~~~\n", "    ",
                  "---\n", "(https://a.b)"]
        for _ in range(400):
            words = []
            source = ""
            for index in range(rng.randrange(1, 12)):
                source += rng.choice(pieces)
                if rng.random() < 0.6:
                    word = "w" + chr(97 + index)
                    words.append(word)
                    source += word
            with self.subTest(source):
                rendered = self.text(source)
                self.assertEqual(re.findall(r"w[a-z]", rendered), words)

    def test_pathological_input_is_quick(self):
        for name, text in [("stars", "*a " * 6000), ("open stars", "**x" * 6000),
                           ("ticks", "`a ``b " * 3000), ("brackets", "[" * 18000),
                           ("nested", "[" * 9000 + "]" * 9000),
                           ("under", "_a " * 6000), ("quotes", "> " * 3000 + "x"),
                           ("lists", "\n".join(" " * i + "- x" for i in range(300))),
                           ("huge", "**x " * 100000)]:
            with self.subTest(name):
                took, kept = self.page.evaluate("""(t) => {
                  const start = performance.now();
                  const box = show(t);
                  return [performance.now() - start, box.textContent.length]; }""", text)
                self.assertLess(took, 1500)
                self.assertGreater(kept, 0)

    def test_a_link_shows_only_its_label(self):
        self.assertEqual(self.text("[label](https://x.org/p)"), "label")

    def test_tool_lines_are_plain(self):
        self.assertEqual(self.page.evaluate(
            "messageElement({role: 'tool', text: '**Bash**'}).innerHTML"), "**Bash**")


if __name__ == "__main__":
    unittest.main()
