# Evidence Checklist

Use this checklist for browser-backed `test-n.md` tasks.

Replace `n` in `test-n.md` with the actual verification task number.

## Mandatory Rules
1. Save screenshot files under the current spec folder's `screenshots/` directory.
What it proves: the image files are durable and can be embedded directly in `test-n.md`.

2. Embed every required screenshot in the matching `test-n.md` with Markdown image syntax.
What it proves: the evidence stays attached to the verification report instead of living only in chat.

3. Capture only the real system page.
What it proves: the evidence is not an annotated, synthetic, or manually edited image.

4. At least one screenshot must show the target page and the target field, state, or result together.
What it proves: the screenshot really supports the verification claim.

5. If one screenshot cannot prove the whole task, capture multiple screenshots and explain what each one proves.
What it proves: the report stays auditable even for multi-step browser tasks.

## Screenshot Naming Convention

Name screenshot files using the pattern `test-<n>-<order>.png`, where `n` is the verification task number and `order` is a two-digit sequence within that task. Examples:

- `screenshots/test-1-01.png` — first screenshot for verification task 1
- `screenshots/test-1-02.png` — second screenshot for verification task 1
- `screenshots/test-2-01.png` — first screenshot for verification task 2

## Tool Notes
- Inspect the page before choosing a selector or capture area.
- Use available browser tools with `page.screenshot({ path: ... })` when the screenshot must be saved for `test-n.md`.
- If a selector is unstable, follow these steps:
  1. Try using a parent container that is stable (a `<section>`, `<form>`, or a component root with a stable `data-` attribute).
  2. If no stable child selector works, capture the full viewport with `page.screenshot({ fullPage: false })`.
  3. In `test-n.md`, add a short explanation for why the broader capture was used, and confirm that the target field or result is still visible in the screenshot.
- API, console, and database output are auxiliary evidence only unless the task is explicitly non-browser.