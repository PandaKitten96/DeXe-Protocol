# Contributing to DeXe Protocol

Thank you for your interest in contributing to DeXe Protocol! 🎉

We welcome contributions from the community. This document outlines the process for contributing to the project.

## 💖 Supporting the Project

If you find DeXe Protocol useful, please consider [becoming a GitHub Sponsor](https://github.com/sponsors/PandaKitten96). Your support helps fund ongoing development, security audits, and community maintenance.

## Getting Started

### Prerequisites

- [Node.js](https://nodejs.org/) v20.x or later
- [npm](https://www.npmjs.com/) v8 or later

### Setup

1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/<your-username>/DeXe-Protocol.git
   cd DeXe-Protocol
   ```
3. Install dependencies:
   ```bash
   npm install
   ```
4. Copy the example environment file and fill in required values:
   ```bash
   cp .env.example .env
   ```

### Running Tests

```bash
npm run test
```

### Running Coverage

```bash
npm run coverage
```

### Linting

```bash
npm run lint-fix
```

## How to Contribute

### Reporting Bugs

- Check the [existing issues](https://github.com/PandaKitten96/DeXe-Protocol/issues) to make sure the bug hasn't been reported yet.
- Open a new issue using the **Bug Report** template and provide as much detail as possible.

### Suggesting Features

- Open a new issue using the **Feature Request** template.
- Describe the problem you're trying to solve and how the proposed feature would help.

### Submitting a Pull Request

1. Create a new branch from `master`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes and write or update tests as needed.
3. Ensure all tests pass:
   ```bash
   npm run test
   ```
4. Ensure linting passes:
   ```bash
   npm run lint-fix
   ```
5. Commit your changes with a clear, descriptive message.
6. Push your branch and open a Pull Request against `master`.
7. Fill in the Pull Request template with all relevant information.

## Code Style

- Solidity code must conform to the style checked by [solhint](https://github.com/protofire/solhint) (see `.solhint.json`).
- JavaScript and JSON files must be formatted with [Prettier](https://prettier.io/) (see `.prettierrc.json`).

Run `npm run lint-fix` before committing to automatically fix most formatting issues.

## Security

If you discover a security vulnerability, **please do not open a public issue**. Instead, report it privately by contacting the maintainers directly or via the GitHub Security Advisory feature. Please review our audit reports in the [`audits/`](./audits) directory for context on the project's security posture.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).
