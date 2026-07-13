from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "Windows" / "CodexDashboard.ps1"


def _strip_powershell_strings_and_comments(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    state = "code"
    here_end = None
    line_start = True

    while i < n:
        if state == "here":
            end = text.find(here_end, i)
            if end == -1:
                raise AssertionError(f"Unterminated PowerShell here-string ending with {here_end!r}")
            out.extend(" " * (end - i + len(here_end)))
            i = end + len(here_end)
            state = "code"
            line_start = False
            continue

        ch = text[i]

        if state == "code":
            if line_start and text.startswith("@'", i):
                state = "here"
                here_end = "\n'@"
                out.extend("  ")
                i += 2
                line_start = False
                continue
            if line_start and text.startswith('@"', i):
                state = "here"
                here_end = '\n"@'
                out.extend("  ")
                i += 2
                line_start = False
                continue
            if ch == "#":
                state = "comment"
                out.append(" ")
                i += 1
                continue
            if ch == "'":
                state = "single"
                out.append(" ")
                i += 1
                continue
            if ch == '"':
                state = "double"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            line_start = ch == "\n"
            i += 1
            continue

        if state == "comment":
            out.append("\n" if ch == "\n" else " ")
            if ch == "\n":
                state = "code"
                line_start = True
            i += 1
            continue

        if state == "single":
            out.append(" ")
            if ch == "'":
                if i + 1 < n and text[i + 1] == "'":
                    out.append(" ")
                    i += 2
                    continue
                state = "code"
            i += 1
            continue

        if state == "double":
            out.append(" ")
            if ch == "`" and i + 1 < n:
                out.append(" ")
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue

    if state in {"single", "double", "here"}:
        raise AssertionError(f"Unterminated PowerShell lexical state: {state}")
    return "".join(out)


def test_powershell_launcher_has_balanced_structural_delimiters():
    text = SCRIPT.read_text()
    stripped = _strip_powershell_strings_and_comments(text)
    pairs = {')': '(', ']': '[', '}': '{'}
    stack = []
    for index, ch in enumerate(stripped):
        if ch in "([{":
            stack.append((ch, index))
        elif ch in pairs:
            assert stack, f"Unexpected {ch!r} at offset {index}"
            opening, opening_index = stack.pop()
            assert opening == pairs[ch], (
                f"Mismatched {opening!r} at offset {opening_index} and {ch!r} at offset {index}"
            )
    assert not stack, f"Unclosed delimiters: {stack[-5:]}"


def test_powershell_overlay_contains_runtime_guard_markers():
    text = SCRIPT.read_text()
    for marker in (
        "Interactive dashboard overlay failed:",
        "if (-not $Script:AutoResumeEnabled) { return }",
        "-WorkingDirectory $Script:ResumeProject",
        "$Script:ResumePrompt.Replace",
        "Test-InteractiveDashboardKey",
    ):
        assert marker in text
