# Contributing to PAGI

Thanks for your interest in contributing to PAGI!

## Quick Start

1. Fork the repository
2. Make your changes
3. Run tests (see below)
4. Submit a pull request

## What to Contribute

**Bug fixes and documentation corrections** - Submit a PR directly. For bugs,
please include a failing test case demonstrating the issue.

**New features, API changes, or significant refactors** - Open an issue first
to discuss the approach. This ensures your time isn't wasted on something that
might not fit the project's direction.

## Code Style

Follow the existing code style. Key conventions:

- 4-space indentation (no tabs)
- Opening braces on same line
- Descriptive variable names
- Keep methods focused and reasonably sized

When in doubt, match what you see in the surrounding code.

## Running Tests

```bash
prove -l t/                      # Quick test run during development
RELEASE_TESTING=1 prove -l t/    # Full test suite - run before submitting PR
```

## AI-Assisted Contributions

AI tools are welcome in your workflow. However, you're responsible for
understanding, testing, and standing behind any code you submit.

## Expectations

This is a volunteer project maintained in my spare time. I cannot commit to
timelines for reviewing PRs or responding to issues.

If your organization needs priority support, expedited PR review, or custom
development, I'm available for contract work. Contact jjnapiork@cpan.org to
discuss.

## Questions?

Open an issue on GitHub or reach out to the maintainer.
