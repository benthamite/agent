"""Tests for the phone page's session view, in headless Chromium with a fake API."""
import json
import unittest
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None

PAGE = Path(__file__).resolve().parents[2] / "etc/agent-remote.html"
SESSION = {"id": "s1", "name": "fixture", "backend": "claude-code", "account": "a",
           "state": "waiting", "changed": 0, "snoozed": False}
GEOMETRY = """() => {
  const rect = (id) => { const r = document.getElementById(id).getBoundingClientRect();
                         return [r.top, r.height]; };
  const message = document.querySelectorAll('.msg')[5];
  return { output: rect('output'), status: rect('status'),
           message: message ? message.getBoundingClientRect().top : null }; }"""


def history():
    messages = []
    for i in range(30):
        messages.append({"role": "user", "text": "question %d" % i, "time": None})
        messages.append({"role": "assistant", "text": "answer **%d** " % i + "words " * 40, "time": None})
    return {"available": True, "session": "x", "redacted": True, "messages": messages,
            "before": 0, "after": 1000, "size": 1000, "gap": False}


def output(state="waiting", screen=None, new=None):
    data = dict(SESSION, state=state, output="terminal **text**\nline two")
    if screen is not None:
        data["screen"] = dict({"status": None, "mode": None, "running": False,
                               "writing": None, "card": None, "options": []}, **screen)
    data["history"] = {"available": True, "session": "x", "redacted": True,
                       "messages": new or [], "before": 0, "after": 1000 + len(new or []),
                       "size": 1000, "gap": False}
    return data


@unittest.skipIf(sync_playwright is None, "playwright is not installed")
class RemotePageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.output = output(screen={"mode": "auto mode on"})
        self.history = history()
        self.keys = []
        self.sent = []
        self.sessions = [SESSION]
        self.sent_to = []
        self.send_error = None
        context = self.browser.new_context(
            viewport={"width": 390, "height": 780}, has_touch=True, is_mobile=True)
        self.addCleanup(context.close)
        self.page = context.new_page()
        self.page.route("**/*", self.handle)
        self.page.goto("http://phone.test/")
        self.page.wait_for_selector(".card")
        self.page.evaluate("clearInterval(timer)")
        self.page.click(".card")
        self.page.wait_for_function("document.querySelectorAll('#output .msg, #live').length > 0")
        self.page.wait_for_timeout(100)
        self.page.evaluate("clearInterval(timer)")

    def handle(self, route):
        url = route.request.url
        if url == "http://phone.test/":
            route.fulfill(body=PAGE.read_text(encoding="utf-8"), content_type="text/html")
        elif "/api/sessions" in url:
            route.fulfill(json={"sessions": self.sessions})
        elif "/api/history" in url:
            route.fulfill(json=self.history)
        elif "/api/output" in url:
            data = self.output
            if "after=" not in url:
                data = {k: v for k, v in data.items() if k != "history"}
            route.fulfill(json=data)
        elif "/api/key" in url:
            self.keys.append(json.loads(route.request.post_data)["key"])
            route.fulfill(json={"ok": True})
        elif "/api/send" in url:
            if self.send_error:
                route.fulfill(status=400, json={"error": self.send_error})
                return
            body = json.loads(route.request.post_data)
            self.sent.append(body["text"])
            self.sent_to.append(body["id"])
            route.fulfill(json={"ok": True})
        else:
            route.fulfill(status=404, json={"error": "not found"})

    def poll(self, data=None):
        if data is not None:
            self.output = data
        self.page.evaluate("refreshSession(false)")
        self.page.wait_for_timeout(50)

    def geometry(self):
        return self.page.evaluate(GEOMETRY)

    def text(self, selector):
        return self.page.evaluate(
            "(s) => document.querySelector(s).textContent", selector)

    def visible(self, selector):
        return self.page.evaluate(
            "(s) => getComputedStyle(document.querySelector(s)).display !== 'none'", selector)

    def scroll_to(self, top):
        self.page.evaluate("(t) => { document.getElementById('output').scrollTop = t; }", top)
        self.page.wait_for_timeout(30)

    def at_bottom(self):
        return self.page.evaluate("isOutputAtBottom()")

    def test_no_terminal_mirror_in_the_normal_state(self):
        self.poll()
        self.assertFalse(self.visible("#live"))
        self.assertFalse(self.visible("#card"))
        self.assertIsNone(self.page.query_selector("#panel"))
        self.assertEqual(self.text("#status-text"), "auto mode on")

    def test_status_line_never_wraps(self):
        self.poll(output("busy", {"status": "Forging… " + "very long status " * 20,
                                  "running": True}))
        height = self.page.evaluate("document.getElementById('status-text').offsetHeight")
        self.assertLess(height, 24)
        self.assertEqual(self.geometry()["status"][1], 44)
        self.assertEqual(self.page.evaluate("document.documentElement.scrollWidth"), 390)

    def test_nothing_shifts_across_states(self):
        """The conversation's place and size hold through every state change."""
        self.scroll_to(1000)
        self.poll()
        before = self.geometry()
        states = [
            output("busy", {"status": "Forging… 1s", "running": True}),
            output("busy", {"status": "Forging… 2s · 1k tokens", "running": True,
                            "writing": "text still being written " * 30}),
            output("waiting", {"card": "A dialog\n❯ 1. Yes\n  2. No", "options": ["1", "2"]}),
            output("waiting", {"card": "tall\n" * 200, "options": []}),
            output("waiting", {"mode": "auto mode on"}),
            output("waiting", {}),
            output("busy", {"status": "x", "running": True}),
            output("waiting", {"card": "unknown"}),
            output("waiting", {"mode": "manual mode on"}),
        ]
        for state in states:
            self.poll(state)
            with self.subTest(state["screen"]):
                self.assertEqual(self.geometry(), before)

    def test_new_message_follows_only_at_the_bottom(self):
        self.page.evaluate("scrollOutputToBottom()")
        self.poll()
        message = {"role": "assistant", "text": "a new one " * 40, "time": None}
        self.poll(output(new=[message], screen={}))
        self.assertTrue(self.at_bottom())
        self.scroll_to(1000)
        place = self.geometry()
        self.poll(output(screen={}, new=[dict(message, text="another")]) | {
            "history": dict(output(new=[dict(message, text="another")])["history"], after=1002)})
        self.assertEqual(self.geometry(), place)

    def test_provisional_message_is_replaced_in_place(self):
        self.page.evaluate("scrollOutputToBottom()")
        text = "This is being written and goes on " * 6
        self.poll(output("busy", {"status": "F…", "running": True, "writing": text}))
        self.assertIn("being written", self.text("#writing"))
        self.assertTrue(self.at_bottom())
        top = self.page.evaluate("document.querySelector('#writing .msg').getBoundingClientRect().top")
        self.poll(output("busy", {"status": "F…", "running": True, "writing": text},
                         new=[{"role": "assistant", "text": text, "time": None}]))
        self.assertEqual(self.text("#writing"), "")
        self.assertEqual(self.page.evaluate(
            "document.querySelector('#messages').lastElementChild.getBoundingClientRect().top"), top)
        self.assertEqual(self.page.evaluate(
            "[...document.querySelectorAll('.msg')].filter(e => e.textContent.includes('being written')).length"), 1)

    def test_written_text_is_not_provisional(self):
        self.poll(output("busy", {"running": True, "writing": "answer 29 words words words"}))
        self.assertEqual(self.text("#writing"), "")

    def test_no_provisional_when_not_busy(self):
        self.poll(output("waiting", {"writing": "something else entirely"}))
        self.assertEqual(self.text("#writing"), "")

    def test_card_shows_all_of_a_tall_dialog(self):
        lines = ["dialog line %d" % i for i in range(200)]
        self.poll(output("waiting", {"card": "\n".join(lines), "options": []}))
        self.assertTrue(self.visible("#card"))
        self.assertEqual(self.text("#card-text"), "\n".join(lines))
        fits = self.page.evaluate("""() => {
          const c = document.getElementById('card').getBoundingClientRect();
          const o = document.getElementById('output').getBoundingClientRect();
          const t = document.getElementById('card-text');
          return [c.height <= 0.75 * o.height, c.bottom <= o.bottom,
                  t.scrollTop + t.clientHeight >= t.scrollHeight - 2]; }""")
        self.assertEqual(fits, [True, True, True])

    def test_under_a_card_the_conversation_can_be_read(self):
        self.page.evaluate("scrollOutputToBottom()")
        self.poll()
        self.poll(output("waiting", {"card": "tall\n" * 200}))
        self.assertTrue(self.at_bottom())
        visible = self.page.evaluate("""() => {
          const o = document.getElementById('output');
          o.scrollTop = o.scrollHeight;
          const last = document.querySelector('#messages').lastElementChild.getBoundingClientRect();
          return last.bottom <= document.getElementById('card').getBoundingClientRect().top; }""")
        self.assertTrue(visible)
        self.assertTrue(self.at_bottom())

    def test_card_rejoins_lines_the_terminal_wrapped(self):
        card = ("\u2500" * 40 + "\n"
                "\u2726 Heads up \u00b7 Rejecting it drops the outreach that was\n"
                "  promised to Max.\n"
                "  1: Learn more   0: Dismiss")
        data = output("waiting", {"card": card, "options": ["1", "0"]})
        data["columns"] = 60
        self.poll(data)
        self.assertEqual(self.text("#card-text"),
                         "\u2500" * 30 + "\n"
                         "\u2726 Heads up \u00b7 Rejecting it drops the outreach that was"
                         " promised to Max.\n"
                         "  1: Learn more   0: Dismiss")

    def test_card_keeps_its_lines_without_a_width(self):
        self.poll(output("waiting", {"card": "a full line\n  and the next"}))
        self.assertEqual(self.text("#card-text"), "a full line\n  and the next")

    def test_card_goes_away(self):
        self.poll(output("waiting", {"card": "A dialog"}))
        self.poll(output("waiting", {}))
        self.assertFalse(self.visible("#card"))
        self.assertEqual(self.page.evaluate("document.getElementById('output').style.paddingBottom"), "")

    def test_terminal_text_stays_unrendered(self):
        self.poll(output("waiting", {"card": "**not bold** ⏵⏵ mode"}))
        self.assertEqual(self.page.evaluate("document.getElementById('card-text').children.length"), 0)
        self.assertIn("**not bold** >> mode", self.text("#card-text"))

    def labels(self, selector):
        return self.page.evaluate(
            "(s) => [...document.querySelectorAll(s + ' button')]"
            ".filter(b => b.offsetParent).map(b => b.textContent)", selector)

    def test_no_keys_at_the_input_box(self):
        self.poll()
        self.assertEqual(self.labels("#session-view #conversation"), [])
        self.assertEqual(self.labels("#status"), ["···"])
        self.assertTrue(self.visible(".compose"))

    def test_stop_while_a_turn_runs(self):
        self.poll(output("busy", {"status": "Forging…", "running": True}))
        self.assertEqual(self.labels("#status"), ["Stop", "···"])
        self.page.click("#stop")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.keys, ["esc"])
        self.poll(output("waiting", {}))
        self.assertEqual(self.labels("#status"), ["···"])

    def test_dialog_keys_with_the_options_on_screen(self):
        self.poll(output("waiting", {"card": "A dialog", "options": ["1", "2", "3"]}))
        self.assertEqual(self.labels("#card"), ["1", "2", "3", "↑", "↓", "Enter", "Esc"])
        self.page.click("#card-keys button:has-text('2')")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.keys, ["2"])
        before = self.page.query_selector("#card-keys button")
        self.poll(output("waiting", {"card": "A dialog", "options": ["1", "2", "3"]}))
        self.assertTrue(before.evaluate("b => b.isConnected"))
        self.poll(output("waiting", {"card": "A notice", "options": ["1", "0"]}))
        self.assertEqual(self.labels("#card"), ["0", "1", "↑", "↓", "Enter", "Esc"])

    def test_more_keys_are_always_there_and_shift_nothing(self):
        self.scroll_to(1000)
        self.poll()
        before = self.geometry()
        self.assertFalse(self.visible("#more"))
        self.page.click("#more-toggle")
        self.assertTrue(self.visible("#more"))
        labels = self.labels("#more")
        for key in ["^C", "y", "n", "Shift Tab", "Tab", "Esc", "↑", "↓", "Enter"]:
            self.assertIn(key, labels)
        self.assertEqual(self.geometry(), before)
        self.page.click("#more button:has-text('^C')")
        self.page.wait_for_timeout(350)
        self.assertEqual(self.keys, ["ctrl-c"])
        self.assertEqual(self.geometry(), before)
        self.page.click("#more-toggle")
        self.assertFalse(self.visible("#more"))
        self.assertEqual(self.geometry(), before)

    def test_keys_do_not_jump_the_view(self):
        self.scroll_to(1000)
        self.poll(output("waiting", {"card": "A dialog", "options": ["1"]}))
        before = self.geometry()
        self.page.click("#card-keys button:has-text('Esc')")
        self.page.wait_for_timeout(400)
        self.assertEqual(self.geometry(), before)

    def test_send_still_works(self):
        self.page.fill("#text", "hello")
        self.page.click("#send")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.sent, ["hello"])

    def open_session(self, name):
        self.page.go_back()
        self.page.wait_for_selector(".card:has-text('%s')" % name)
        self.page.evaluate("clearInterval(timer)")
        self.page.click(".card:has-text('%s')" % name)
        self.page.wait_for_timeout(100)
        self.page.evaluate("clearInterval(timer)")

    def test_each_session_keeps_its_own_draft(self):
        self.sessions = [SESSION, dict(SESSION, id="s2", name="second")]
        self.page.fill("#text", "a reply to the first")
        self.open_session("second")
        self.assertEqual(self.page.input_value("#text"), "")
        self.page.fill("#text", "a reply to the second")
        self.open_session("fixture")
        self.assertEqual(self.page.input_value("#text"), "a reply to the first")
        self.open_session("second")
        self.assertEqual(self.page.input_value("#text"), "a reply to the second")
        self.page.click("#send")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.sent, ["a reply to the second"])
        self.assertEqual(self.sent_to, ["s2"])
        self.open_session("fixture")
        self.assertEqual(self.page.input_value("#text"), "a reply to the first")
        self.open_session("second")
        self.assertEqual(self.page.input_value("#text"), "")

    def test_drafts_survive_a_reload(self):
        self.page.fill("#text", "half a thought")
        self.page.reload()
        self.page.wait_for_selector(".card")
        self.page.evaluate("clearInterval(timer)")
        self.page.click(".card")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.page.input_value("#text"), "half a thought")

    def test_refused_send_keeps_the_draft(self):
        self.send_error = "The session shows a dialog; answer it first"
        self.page.fill("#text", "a long reply")
        self.page.click("#send")
        self.page.wait_for_timeout(100)
        self.assertEqual(self.page.input_value("#text"), "a long reply")
        self.assertIn("answer it first", self.text("#messages"))
        self.open_session("fixture")
        self.assertEqual(self.page.input_value("#text"), "a long reply")

    def test_no_glyph_a_phone_font_lacks(self):
        page = self.page.evaluate("document.getElementById('session-view').textContent"
                                  " + MORE_KEYS.flat(2).join() + CARD_KEYS.flat().join()")
        for glyph in "⏵⏸⇧⋯":
            self.assertNotIn(glyph, page)

    def test_session_without_a_transcript_keeps_the_whole_screen(self):
        self.page.go_back()
        self.history = {"available": False}
        self.output = dict(SESSION, output="whole screen ⏵ here " + "wide " * 40)
        self.page.wait_for_selector(".card")
        self.page.click(".card")
        self.page.wait_for_function("document.getElementById('live').textContent.includes('whole')")
        self.page.evaluate("clearInterval(timer)")
        self.assertTrue(self.visible("#live"))
        self.assertIn("> here", self.text("#live"))
        self.assertEqual(self.page.evaluate("""() => {
          const o = document.getElementById('output');
          return [getComputedStyle(document.getElementById('live')).whiteSpace,
                  o.scrollWidth <= o.clientWidth,
                  !!document.getElementById('wrap')]; }"""), ["pre-wrap", True, False])
        self.assertFalse(self.visible("#card"))
        self.assertTrue(self.visible("#status"))
        self.assertEqual(self.page.evaluate("document.querySelectorAll('.msg').length"), 0)
        self.assertTrue(self.visible("#more"))
        self.assertIn("^C", self.labels("#more"))
        self.page.click("#more-toggle")
        self.assertFalse(self.visible("#more"))
        self.poll()
        self.assertFalse(self.visible("#more"))

    def test_lost_transcript_is_said_over_the_screen(self):
        self.page.go_back()
        self.history = {"available": False, "pending": False,
                        "lost": "Emacs lost this session's transcript."}
        self.output = dict(SESSION, output="whole screen here")
        self.page.wait_for_selector(".card")
        self.page.click(".card")
        self.page.wait_for_function("document.getElementById('live').textContent.includes('whole')")
        self.page.evaluate("clearInterval(timer)")
        self.assertTrue(self.visible("#live"))
        self.assertTrue(self.visible("#history-bar"))
        self.assertIn("lost this session's transcript", self.text("#history-note"))
        self.assertNotIn("fresh", self.page.evaluate("document.getElementById('session-view').className"))

if __name__ == "__main__":
    unittest.main()
