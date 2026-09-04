import unittest
import trace_receipt as tr


class ParseTest(unittest.TestCase):
    def test_records(self):
        self.assertEqual(tr.parse("spawn\tAccount#1\n"), {"kind": "spawn", "actor": "Account#1"})
        self.assertEqual(tr.parse("send\t\tBank#2\ttake\tref<Account:1>, 200\t800")["from"], "")
        self.assertEqual(tr.parse("cast\t\tSink#1\tput\t7")["reply"], None)
        self.assertEqual(tr.parse("state\tAccount#1\tbalance\t800")["value"], "800")
        self.assertIsNone(tr.parse("garbage line"))


class FramerTest(unittest.TestCase):
    def test_nested_sends_group_under_their_top_level_send(self):
        f = tr.Framer()
        for l in [
            "spawn\tAccount#1", "spawn\tBank#2",
            "state\tAccount#1\tbalance\t800",
            "send\tBank#2\tAccount#1\twithdraw\t200\t800",
            "send\tBank#2\tAccount#1\tget\t\t800",
            "send\t\tBank#2\ttake\tref<Account:1>, 200\t800",
        ]:
            f.push(tr.parse(l))
        frames = f.take()
        self.assertEqual([h["kind"] for h, _ in frames], ["spawn", "spawn", "send"])
        head, body = frames[2]
        self.assertEqual(head["msg"], "take")
        self.assertEqual([r["kind"] for r in body], ["state", "send", "send"])
        self.assertEqual(f.take(), [])

    def test_cast_frame_has_no_reply(self):
        f = tr.Framer()
        f.push(tr.parse("cast\t\tSink#1\tput\t7"))
        f.push(tr.parse("state\tSink#1\tseen\t7"))
        head, body = f.take()[0]
        self.assertIsNone(head["reply"])
        # the become happened after the cast returned, so it waits for the next frame
        self.assertEqual(body, [])
        self.assertEqual(len(f.pending), 1)


class RenderTest(unittest.TestCase):
    def test_markdown_shape_and_clipping(self):
        f = tr.Framer()
        f.push(tr.parse("spawn\tAccount#1"))
        f.push(tr.parse("state\tAccount#1\tbalance\t" + "9" * 100))
        f.push(tr.parse("send\t\tAccount#1\twithdraw\t200\t800"))
        md = tr.render(f.take(), title="T", when="12:00:00")
        self.assertTrue(md.startswith("# T\n\n12:00:00\n"))
        self.assertIn("spawn **Account#1**", md)
        self.assertIn("## Account#1 :withdraw(200)", md)
        self.assertIn("```\n  * Account#1.balance = 9", md)
        self.assertIn("  => 800\n```", md)
        for line in md.split("\n"):
            self.assertLessEqual(len(line), tr.COLS)


class FeederTest(unittest.TestCase):
    def lines(self):
        return ["spawn\tCounter#1", "state\tCounter#1\tcount\t1", "send\t\tCounter#1\tincrement\t\t1",
                "send\t\tCounter#1\tget\t\t1"]

    def test_short_run_becomes_one_receipt(self):
        sent = []
        f = tr.Feeder(sent.append, every=15.0)
        for l in self.lines():
            f.line(l)
        self.assertEqual(sent, [])
        f.finish()
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0].count("# BLIMP TRACE"), 1)
        self.assertIn("spawn **Counter#1**", sent[0])
        self.assertIn("## Counter#1 :get", sent[0])

    def test_rate_limit_keeps_frames_and_retries(self):
        calls = []
        slept = []

        def sender(md):
            calls.append(md)
            if len(calls) == 1:
                raise tr.RateLimited(3)

        f = tr.Feeder(sender, every=15.0, sleep=slept.append)
        for l in self.lines():
            f.line(l)
        f.finish()
        self.assertEqual(slept, [3.5])
        self.assertEqual(f.printed, 1)
        self.assertEqual(len(calls), 2)
        self.assertEqual(f.framer.frames, [])
        self.assertEqual(calls[-1].count("## Counter#1 :"), 2)

    def test_other_errors_do_not_lose_frames(self):
        def sender(md):
            raise RuntimeError("500 boom")

        f = tr.Feeder(sender, every=0)
        f.line("send\t\tCounter#1\tget\t\t1")
        f.finish()
        self.assertEqual(f.printed, 0)
        self.assertEqual(len(f.framer.frames), 1)


if __name__ == "__main__":
    unittest.main()
