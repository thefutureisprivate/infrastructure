# AGENTS.md

Project overview is available at `README.md`.

This project is security-focused, and aims to be clean and elegant.

## General guidelines

Some guidelines are:

- Make changes carefully with security hardening in mind.
- Keep things auditable and readable.
- Do not add unnecessary features or useless/redundant code.

In general, follow zero trust principles as much as possible.

## Code Conventions

Keep code and configurations simple, explicit, and boring.

## Validation

Run relevant checks after changes:

- `yamllint .`
- `ansible-lint <file/dir>`
- `ansible-playbook -i inventory.yml --syntax-check <file>`

## Workflow

When making contributions on behalf of the user, be clear and informative
about the changes that were made and the reasoning behind them.
