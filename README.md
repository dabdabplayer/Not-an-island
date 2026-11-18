
# Not an Island

**Not an Island** is an open source, all-in-one Dynamic Island-style application for MacBooks with a physical display notch.

The project turns the space around the MacBook's notch into a shared, context-aware interface for useful activities and controls. Rather than creating a collection of unrelated floating windows, Not an Island is designed around one consistent notch experience.

> **Project status:** Early development. Music is the first feature being implemented; the broader product vision is described below.

---

## Vision

Not an Island aims to bring useful, glanceable interactions to the MacBook notch, including:

- **Music:** playback information, artwork, visualisation, and controls.
- **File shelf:** temporary file storage and drag-and-drop workflows.
- **Notifications and live activities:** relevant updates without interrupting the user's work.
- **System monitoring:** useful system status and resource information.
- **Calendar and productivity:** upcoming events, timers, and small workflow utilities.
- **Clipboard:** quick access to recent copied content.
- **Extensions:** an open ecosystem for additional capabilities.

These are planned areas, not a claim that every feature is currently implemented.

## Platform

- macOS 15 Sequoia or newer.
- Designed for MacBooks with a physical display notch.

---

## Design principles

- **One shared notch interface:** features integrate with the shared notch experience instead of creating their own independent notch windows.
- **Focused interactions:** information and controls should be easy to glance at and use.
- **Modular implementation:** capabilities live in feature-specific modules while shared window and activity behaviour stays in the core.
- **Native where practical:** prefer documented Apple frameworks and APIs.
- **Privacy and reliability:** respect macOS permissions and user privacy; do not depend on private APIs or undocumented system behaviour.

## Development

The project is built for macOS using Swift. The intended project setup is an Xcode project with Swift Package Manager for dependency management, and Swift 6 strict concurrency checking.

The UI architecture and implementation details should follow the decisions documented in the repository as development progresses. Do not assume an undocumented command, scheme, or target: inspect the Xcode project and use the schemes and targets that actually exist.

---

## Contributing

Contributions are welcome. Please keep changes focused, follow the existing project structure and conventions, and explain the problem your change solves.

### Pull request requirements

Every pull request must meet all of the following requirements:

1. **All tests must pass.** Run the relevant test suite and include the results in your pull request. A pull request that causes existing tests to fail, or introduces failing tests, is not ready to merge.
2. **Add or update tests.** Changes to behaviour should include appropriate tests. Bug fixes should include a regression test where practical.
3. **Review your changes.** Read through every line of code you submit. Check for correctness, security, privacy, performance, maintainability, and unintended side effects.
4. **Validate the result.** Build and test your changes in the relevant environment. Do not claim that checks passed unless you actually ran them.
5. **Describe the contribution.** Explain what changed, why it was needed, and how you tested it. Disclose known limitations or untested areas.

### Use of AI

AI-assisted development tools are allowed. However, using AI does not transfer or reduce the contributor's responsibility.

If you use AI to generate, modify, review, or debug code, you are still fully responsible for the submitted contribution. Before opening a pull request, you must:

- Personally review and understand all submitted code, including AI-generated code.
- Verify that the implementation is correct and appropriate for this project.
- Run the relevant builds and tests yourself and confirm that they pass.
- Check for fabricated APIs, insecure patterns, licensing issues, and unsupported assumptions.
- Be able to explain and maintain the code you submit.

AI output must not be treated as verified simply because a tool generated it or reported that it was correct. The contributor is responsible for the code and for ensuring that it has been reviewed and tested by a human.

By submitting a pull request, you confirm that you have reviewed the contribution and take responsibility for its correctness, quality, and compliance with the project's requirements. The project maintainers may request changes or decline contributions that do not meet these standards.

### Before opening a pull request

- Check the existing issues and pull requests to avoid duplicate work.
- Keep the pull request focused on one change where possible.
- Follow the established architecture and coding conventions.
- Include tests for new or changed behaviour.
- Run the relevant build and test commands and report the actual results.
- Never include secrets, credentials, personal data, or unrelated generated files.

---

## Forking and Derivative Works

By forking, modifying, or redistributing Not an Island, you agree to comply with the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.

In particular:

- Any distributed derivative work or modified version covered by the GPL must be released under GPL-3.0-or-later, with its corresponding source code made available under the terms of the license.
- The original Not an Island project must be properly credited, and its copyright and license notices must be preserved.
- Derivative works must remain open source under the applicable GPL terms. Their source code must be accessible to recipients, who retain the rights granted by the license to use, study, modify, and redistribute it.

**Not an Island is built on the principle of open collaboration.** We welcome forks, modifications, and contributions, provided they respect these licensing requirements.

---

## License

Not an Island is licensed under GNU General Public License v3.0 or later (GPL-3.0-or-later). See the LICENSE file for the full license text.

By contributing, you agree that your contribution is submitted under the same license, unless the project explicitly states otherwise.
