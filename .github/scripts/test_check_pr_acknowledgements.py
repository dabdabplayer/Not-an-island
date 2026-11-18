import unittest

from check_pr_acknowledgements import REQUIRED, missing_acknowledgements


def body(*states: str) -> str:
    return "\n".join(f"- [{state}] {item}" for state, item in zip(states, REQUIRED))


class MissingAcknowledgementsTests(unittest.TestCase):
    def test_all_checked_passes(self):
        self.assertEqual(missing_acknowledgements(body("x", "x", "X", "x")), [])

    def test_one_unchecked_is_reported(self):
        self.assertEqual(missing_acknowledgements(body("x", " ", "x", "x")), [REQUIRED[1]])

    def test_empty_description_reports_everything(self):
        self.assertEqual(missing_acknowledgements(""), REQUIRED)

    def test_deleted_line_counts_as_unchecked(self):
        text = "\n".join(f"- [x] {item}" for item in REQUIRED[:3])
        self.assertEqual(missing_acknowledgements(text), [REQUIRED[3]])

    def test_reworded_line_counts_as_unchecked(self):
        text = body("x", "x", "x", "x").replace("all relevant tests pass", "most tests pass")
        self.assertEqual(missing_acknowledgements(text), [REQUIRED[2]])

    def test_windows_line_endings_curly_apostrophes_and_asterisks_pass(self):
        text = body("x", "x", "x", "x").replace("README's", "README’s").replace("- [", "* [").replace("\n", "\r\n")
        self.assertEqual(missing_acknowledgements(text), [])

    def test_checkbox_inside_a_quote_does_not_count(self):
        text = "\n".join(f"> - [x] {item}" for item in REQUIRED)
        self.assertEqual(missing_acknowledgements(text), REQUIRED)


if __name__ == "__main__":
    unittest.main()
