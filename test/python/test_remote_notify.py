"""Tests for the phone page's notification bell, with a fake Agents app bridge."""
import unittest
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None

PAGE = Path(__file__).resolve().parents[2] / "etc/agent-remote.html"
SESSIONS = [
    {"id": "s1", "name": "one", "backend": "claude-code", "account": "a",
     "state": "waiting", "changed": 0, "snoozed": False},
    {"id": "s2", "name": "two", "backend": "claude-code", "account": "a",
     "state": "busy", "changed": 0, "snoozed": False},
]
# What the app's bridge does, minus Android: it records the calls and
# grants modes at once unless told to wait for a permission answer.
FAKE_APP = """
window.appCalls = [];
window.appMode = "off";
window.appAsks = false;
window.AgentApp = {
  notifyMode: () => window.appMode,
  setNotifyMode: (m) => {
    window.appCalls.push(["mode", m]);
    if (window.appAsks && m !== "off") return window.appMode;
    window.appMode = m;
    return m;
  },
  setViewing: (id) => window.appCalls.push(["viewing", id]),
};
"""


@unittest.skipIf(sync_playwright is None, "playwright is not installed")
class RemoteNotifyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def open(self, with_app):
        context = self.browser.new_context(
            viewport={"width": 390, "height": 780}, has_touch=True, is_mobile=True)
        self.addCleanup(context.close)
        if with_app:
            context.add_init_script(FAKE_APP)
        page = context.new_page()
        page.route("**/*", self.handle)
        page.goto("http://phone.test/")
        page.wait_for_selector(".card")
        return page

    def handle(self, route):
        url = route.request.url
        if url == "http://phone.test/":
            route.fulfill(body=PAGE.read_text(encoding="utf-8"), content_type="text/html")
        elif "/api/sessions" in url:
            route.fulfill(json={"sessions": SESSIONS})
        elif "/api/output" in url:
            sid = url.split("id=")[1].split("&")[0]
            name = next(s["name"] for s in SESSIONS if s["id"] == sid)
            route.fulfill(json={"id": sid, "name": name, "state": "waiting",
                                "output": "screen"})
        elif "/api/history" in url:
            route.fulfill(json={"available": False})
        else:
            route.fulfill(status=404, json={"error": "not found"})

    @staticmethod
    def bell(page, selector):
        return page.evaluate("""(s) => { const b = document.querySelector(s);
          return { hidden: b.hidden, on: b.classList.contains('on'), label: b.title,
                   paths: b.querySelector('path').getAttribute('d').split('M').length }; }""",
                             selector)

    def test_bell_hidden_in_a_browser(self):
        page = self.open(with_app=False)
        self.assertTrue(self.bell(page, "#list-notify")["hidden"])
        self.assertTrue(self.bell(page, "#notify")["hidden"])

    def test_bell_cycles_off_visual_sound(self):
        page = self.open(with_app=True)
        start = self.bell(page, "#list-notify")
        self.assertFalse(start["hidden"])
        self.assertFalse(start["on"])
        self.assertEqual(start["label"], "Notifications off")
        page.click("#list-notify")
        visual = self.bell(page, "#list-notify")
        self.assertTrue(visual["on"])
        self.assertIn("no sound", visual["label"])
        page.click("#list-notify")
        sound = self.bell(page, "#notify")
        self.assertIn("and sound", sound["label"])
        self.assertGreater(sound["paths"], visual["paths"])
        page.click("#list-notify")
        self.assertEqual(self.bell(page, "#list-notify")["label"], "Notifications off")
        self.assertEqual(page.evaluate("appCalls"),
                         [["mode", "visual"], ["mode", "sound"], ["mode", "off"]])

    def test_bell_waits_for_permission(self):
        page = self.open(with_app=True)
        page.evaluate("appAsks = true")
        page.click("#list-notify")
        self.assertFalse(self.bell(page, "#list-notify")["on"])
        page.evaluate("agentNotifyModeChanged('visual')")
        self.assertTrue(self.bell(page, "#list-notify")["on"])

    def test_app_hears_the_session_on_show(self):
        page = self.open(with_app=True)
        page.click(".card")
        page.wait_for_selector("#session-view.active")
        page.evaluate("history.back()")
        page.wait_for_selector("#list-view.active")
        viewing = [c[1] for c in page.evaluate("appCalls") if c[0] == "viewing"]
        self.assertEqual(viewing, ["s1", ""])

    def test_tapped_notification_opens_its_session(self):
        page = self.open(with_app=True)
        page.evaluate("agentOpenSession('s2', 'two')")
        page.wait_for_selector("#session-view.active")
        self.assertEqual(page.evaluate("current"), "s2")
        page.evaluate("agentOpenSession('s1', 'one')")
        page.wait_for_function("document.getElementById('session-title').textContent === 'one'")
        self.assertEqual(page.evaluate("current"), "s1")
        # Opening one session over another replaces it, so Back reaches the list.
        page.evaluate("history.back()")
        page.wait_for_selector("#list-view.active")


if __name__ == "__main__":
    unittest.main()
