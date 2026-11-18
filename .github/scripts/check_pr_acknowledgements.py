"""Fails unless every required acknowledgement is checked in the pull request description.

Reads the description from the PR_BODY environment variable, so its text is never run as code.
"""

import os
import re
import sys

REQUIRED = [
    "I have read and understood the README's contribution requirements.",
    "I have reviewed and tested all submitted code, including AI-generated code, and accept full responsibility.",
    "I confirm all relevant tests pass.",
    "I agree to comply with the GPL-3.0-or-later licensing requirements.",
]

CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(.*?)\s*$")


def normalise(text: str) -> str:
    # GitHub's editor may turn straight apostrophes into curly ones.
    return " ".join(text.replace("’", "'").split())


def missing_acknowledgements(body: str) -> list[str]:
    checked = set()
    for line in body.splitlines():
        match = CHECKBOX.match(line)
        if match and match.group(1) in "xX":
            checked.add(normalise(match.group(2)))
    return [item for item in REQUIRED if normalise(item) not in checked]


def main() -> int:
    missing = missing_acknowledgements(os.environ.get("PR_BODY", ""))
    if not missing:
        print("All acknowledgements are checked.")
        return 0
    print("These acknowledgements must be checked in the pull request description:")
    for item in missing:
        print(f"  - [ ] {item}")
        # Shows each one as an error annotation on the pull request.
        print(f"::error title=Unchecked acknowledgement::{item}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
