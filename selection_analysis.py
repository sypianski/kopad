#!/usr/bin/env python3
"""
Gamepad text selection analysis for KoPad.

Simulates a realistic book page and calculates the average button presses
needed to select any word or sentence under different selection strategies.

Gamepad assumed inputs:
  D-pad:    Up / Down / Left / Right  (4 buttons)
  Buttons:  A (confirm) / B (cancel) / X / Y  (4 buttons)
  Bumpers:  LB / RB  (2 buttons)
  Triggers: LT / RT  (optional analog, treated as buttons)
  Sticks:   L-stick / R-stick  (each = 2-axis + click)

Total: ~14 discrete inputs. But comfort zone is D-pad + A/B/X/Y = 8 buttons.
"""

import random
import math
import statistics
from dataclasses import dataclass

# ── Realistic page of text ──────────────────────────────────────────

PAGE_TEXT = """\
The fruit trees of the Mediterranean basin underwent a remarkable transformation \
during the early Islamic period. Citrus varieties, including the lemon, bitter \
orange, and shaddock, were introduced from South and Southeast Asia through \
networks of trade and scholarly exchange. These crops required careful irrigation \
and could not survive the dry summers without intervention.

Ibn Wahshiyya describes the cultivation of eggplant in detail, noting that it \
must be planted in rich soil during the warm months. He recommends frequent \
watering and protection from wind. The plant yields best when given adequate \
spacing between rows. Farmers in lower Iraq grew it alongside watermelon and \
sugarcane in irrigated plots near the canals.

Cotton was among the most economically significant of the new arrivals. Its \
cultivation spread rapidly across the Jazira, Egypt, and parts of al-Andalus. \
The fiber required extensive processing after harvest, including ginning, \
carding, and spinning. Agricultural manuals devote considerable attention to \
soil preparation, noting that cotton exhausts the earth and must be rotated \
with restorative crops such as clover or fenugreek.

Sorghum, known in Arabic sources as dhura, served as a staple grain for much \
of the population in areas too dry or too hot for wheat. It was particularly \
important in Upper Egypt, Yemen, and the Sahel. Unlike wheat, sorghum could be \
planted in summer and tolerated poor soils. Markets in Fustat and Alexandria \
traded sorghum flour alongside wheat, barley, and rice."""


def build_page():
    lines_raw = PAGE_TEXT.strip().split("\n")
    paragraphs = []
    current = []
    for line in lines_raw:
        if line.strip() == "":
            if current:
                paragraphs.append(" ".join(current))
                current = []
        else:
            current.append(line.strip())
    if current:
        paragraphs.append(" ".join(current))

    sentences = []
    words = []
    word_idx = 0
    for para in paragraphs:
        sent_buf = []
        for w in para.split():
            word_entry = {"text": w, "index": word_idx, "para": len(paragraphs)}
            words.append(word_entry)
            sent_buf.append(word_idx)
            word_idx += 1
            if w.endswith((".","!","?")) and not w[-2:-1].isupper():
                sentences.append(sent_buf[:])
                sent_buf = []
        if sent_buf:
            sentences.append(sent_buf[:])

    # Wrap words into lines (~65 chars wide, typical e-reader)
    lines = []
    current_line = []
    current_len = 0
    line_width = 65
    for w in words:
        wlen = len(w["text"])
        if current_len + wlen + (1 if current_line else 0) > line_width and current_line:
            lines.append([x["index"] for x in current_line])
            current_line = []
            current_len = 0
        current_line.append(w)
        current_len += wlen + (1 if len(current_line) > 1 else 0)
    if current_line:
        lines.append([x["index"] for x in current_line])

    return words, sentences, lines


@dataclass
class Result:
    name: str
    description: str
    avg_word: float
    avg_sentence: float
    worst_word: int
    worst_sentence: int
    total_buttons: int


def method_1_linear_scan(words, sentences, lines):
    """
    Linear cursor: D-pad Left/Right moves word by word. A to confirm start,
    A again to confirm end. Like a 1D cursor.

    To select word i: move |i - start| presses + 1 confirm.
    Start at word 0.  Average over all words as target.
    """
    n = len(words)

    # For each target word, presses = distance_from_center + 1 (confirm)
    # Best starting position = middle of page
    start = n // 2

    word_presses = []
    for i in range(n):
        presses = abs(i - start) + 1  # move + confirm
        word_presses.append(presses)

    # For sentence: navigate to first word of sentence, confirm, navigate to last, confirm
    sent_presses = []
    for sent in sentences:
        first, last = sent[0], sent[-1]
        # Assume cursor resets to middle each time
        to_first = abs(first - start) + 1
        to_last = abs(last - first) + 1  # extend from first to last
        sent_presses.append(to_first + to_last)

    return Result(
        name="Linear scan",
        description="Left/Right moves word-by-word from center. A = confirm.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=3,  # Left, Right, A
    )


def method_2_line_then_word(words, sentences, lines):
    """
    Two-phase: Up/Down selects line, then Left/Right selects word within line.
    A = confirm word. Double-tap A or hold = select whole sentence containing word.

    Presses to select word: |line_dist| + |word_offset_in_line| + 1
    Start at middle line, middle word.
    """
    n_lines = len(lines)
    start_line = n_lines // 2

    # Build word-to-line map
    word_to_line = {}
    for li, line in enumerate(lines):
        for pos, widx in enumerate(line):
            word_to_line[widx] = (li, pos, len(line))

    word_presses = []
    for w in words:
        li, pos, line_len = word_to_line[w["index"]]
        line_mid = line_len // 2
        presses = abs(li - start_line) + abs(pos - line_mid) + 1
        word_presses.append(presses)

    sent_presses = []
    for sent in sentences:
        first_w = sent[0]
        li, pos, line_len = word_to_line[first_w]
        line_mid = line_len // 2
        # Navigate to first word, confirm, then done (sentence = auto-detected)
        presses = abs(li - start_line) + abs(pos - line_mid) + 1
        sent_presses.append(presses)

    return Result(
        name="Line → Word (2-phase)",
        description="Up/Down picks line, Left/Right picks word in line. A = confirm.\n"
                    "    Sentence auto-detected from confirmed word.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=5,  # Up, Down, Left, Right, A
    )


def method_3_sentence_first(words, sentences, lines):
    """
    Visel-inspired (keyreader approach adapted for gamepad):
    Up/Down navigates sentences. A = confirm sentence.
    Then X = enter word mode, Left/Right picks word within sentence.

    Sentence selection: distance from middle sentence.
    Word selection: sentence presses + 1 (X) + word offset + 1 (A).
    """
    n_sent = len(sentences)
    start_sent = n_sent // 2

    sent_presses = []
    for i in range(n_sent):
        presses = abs(i - start_sent) + 1  # navigate + confirm
        sent_presses.append(presses)

    word_presses = []
    for si, sent in enumerate(sentences):
        sent_dist = abs(si - start_sent)
        mid_word = len(sent) // 2
        for j, widx in enumerate(sent):
            # Navigate to sentence + X (word mode) + navigate word + A
            presses = sent_dist + 1 + abs(j - mid_word) + 1
            word_presses.append(presses)

    return Result(
        name="Sentence → Word (visel-style)",
        description="Up/Down picks sentence, A = confirm. X = word mode,\n"
                    "    Left/Right picks word. Mirrors keyreader visel.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=6,  # Up, Down, Left, Right, A, X
    )


def method_4_binary_bisect(words, sentences, lines):
    """
    Binary search / bisection:
    Screen split in half. LB = top half, RB = bottom half.
    Each press halves the remaining candidates.
    After narrowing to a single line, Left/Right picks word.

    Presses to reach a line: ceil(log2(n_lines))
    Then word offset within line.
    """
    n_lines = len(lines)
    line_presses = math.ceil(math.log2(max(n_lines, 1)))

    word_to_line = {}
    for li, line in enumerate(lines):
        for pos, widx in enumerate(line):
            word_to_line[widx] = (li, pos, len(line))

    word_presses = []
    for w in words:
        li, pos, line_len = word_to_line[w["index"]]
        # Binary search to line + binary search within line + confirm
        in_line_presses = math.ceil(math.log2(max(line_len, 1)))
        presses = line_presses + in_line_presses + 1
        word_presses.append(presses)

    sent_presses = []
    for sent in sentences:
        first_w = sent[0]
        li, pos, line_len = word_to_line[first_w]
        in_line_presses = math.ceil(math.log2(max(line_len, 1)))
        presses = line_presses + in_line_presses + 1
        sent_presses.append(presses)

    return Result(
        name="Binary bisection",
        description="LB/RB splits screen vertically, then horizontally.\n"
                    "    O(log n) convergence. Feels like 20-questions.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=5,  # LB, RB, Left, Right, A
    )


def method_5_crosshair(words, sentences, lines):
    """
    Crosshair / 2D cursor:
    Left stick moves a crosshair freely over the page.
    Nearest word to crosshair is highlighted. A = confirm.

    Model: crosshair starts at center of page.
    Movement is by line vertically, by word horizontally.
    Same as method 2 mechanically, but uses analog stick:
    assume ~2 stick flicks per line and ~1 per 3 words (faster than D-pad).

    But analog precision is poor — add +1 for fine-tuning average.
    """
    n_lines = len(lines)
    start_line = n_lines // 2

    word_to_line = {}
    for li, line in enumerate(lines):
        for pos, widx in enumerate(line):
            word_to_line[widx] = (li, pos, len(line))

    word_presses = []
    for w in words:
        li, pos, line_len = word_to_line[w["index"]]
        line_mid = line_len // 2
        vert_flicks = math.ceil(abs(li - start_line) / 2)
        horiz_flicks = math.ceil(abs(pos - line_mid) / 3)
        presses = vert_flicks + horiz_flicks + 1 + 1  # +1 fine-tune, +1 confirm
        word_presses.append(presses)

    sent_presses = []
    for sent in sentences:
        first_w = sent[0]
        li, pos, line_len = word_to_line[first_w]
        line_mid = line_len // 2
        vert_flicks = math.ceil(abs(li - start_line) / 2)
        horiz_flicks = math.ceil(abs(pos - line_mid) / 3)
        presses = vert_flicks + horiz_flicks + 1 + 1
        sent_presses.append(presses)

    return Result(
        name="Analog crosshair",
        description="L-stick moves crosshair, nearest word highlights. A = confirm.\n"
                    "    Fast but imprecise — needs fine-tune correction.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=2,  # L-stick, A
    )


def method_6_paragraph_sentence_word(words, sentences, lines):
    """
    3-tier hierarchical (paragraph → sentence → word):
    Up/Down picks paragraph (4 on this page).
    LB/RB picks sentence within paragraph.
    Left/Right picks word within sentence (or skip for sentence select).
    A = confirm at any level.

    This minimizes presses by exploiting document structure.
    """
    # Build paragraph structure
    paragraphs_text = PAGE_TEXT.strip().split("\n\n")
    n_paras = len(paragraphs_text)
    start_para = n_paras // 2

    # Map sentences to paragraphs
    para_sentences = []
    word_offset = 0
    for pt in paragraphs_text:
        para_sents = []
        for raw_sent in _split_sentences(pt):
            wds = raw_sent.split()
            if wds:
                indices = list(range(word_offset, word_offset + len(wds)))
                para_sents.append(indices)
                word_offset += len(wds)
        para_sentences.append(para_sents)

    # Sentence selection: para_dist + sent_dist_within_para + 1
    sent_presses = []
    for pi, para in enumerate(para_sentences):
        n_s = len(para)
        start_s = n_s // 2
        for si, sent in enumerate(para):
            presses = abs(pi - start_para) + abs(si - start_s) + 1
            sent_presses.append(presses)

    # Word selection: para_dist + sent_dist + word_dist + 2 (enter word mode + confirm)
    word_presses = []
    for pi, para in enumerate(para_sentences):
        n_s = len(para)
        start_s = n_s // 2
        for si, sent in enumerate(para):
            mid_w = len(sent) // 2
            for wi, widx in enumerate(sent):
                presses = abs(pi - start_para) + abs(si - start_s) + abs(wi - mid_w) + 2
                word_presses.append(presses)

    return Result(
        name="Paragraph → Sentence → Word (3-tier)",
        description="Up/Down picks paragraph. LB/RB picks sentence in para.\n"
                    "    Left/Right picks word. A = confirm at any tier.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=7,  # Up, Down, LB, RB, Left, Right, A
    )


def method_7_numbered_labels(words, sentences, lines):
    """
    Numbered labels (like visel with numbers):
    Each sentence gets a number label (1-N). Player types the number.
    1-digit: 1 press. 2-digit: 2 presses. Then A.

    For words: select sentence by number, then word by number within sentence.

    Requires mapping D-pad/buttons to digit entry — could use:
    - D-pad up/down to increment digit, A to confirm digit
    - Or dedicate Y/X/B/A as 1/2/3/4 + combos
    - Simplest: D-pad cycles 0-9, A confirms each digit

    Model: digits typed with D-pad cycling (avg 4.5 presses per digit).
    """
    n_sent = len(sentences)

    sent_presses = []
    for i in range(n_sent):
        label = str(i + 1)
        # Each digit: avg 4.5 D-pad presses + 1 confirm
        presses = len(label) * 5.5  # approximate D-pad digit entry
        sent_presses.append(presses)

    word_presses = []
    for si, sent in enumerate(sentences):
        sent_label = str(si + 1)
        sent_cost = len(sent_label) * 5.5
        for wi in range(len(sent)):
            word_label = str(wi + 1)
            word_cost = len(word_label) * 5.5
            presses = sent_cost + word_cost
            word_presses.append(presses)

    return Result(
        name="Numbered labels (D-pad digit entry)",
        description="Sentences labeled 1-N. D-pad cycles digits, A confirms.\n"
                    "    Direct jump but digit entry is slow without a numpad.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=5,  # Up, Down, A, (Left/Right for word mode)
    )


def method_8_hybrid_sentence_bisect(words, sentences, lines):
    """
    HYBRID: Sentence-first with binary word bisection.
    Up/Down navigates sentences (from center).
    A = confirm sentence (done for sentence selection).
    X = enter word mode → LB/RB bisects words within sentence.

    Combines the natural document structure (sentences) with
    logarithmic word convergence.
    """
    n_sent = len(sentences)
    start_sent = n_sent // 2

    sent_presses = []
    for i in range(n_sent):
        presses = abs(i - start_sent) + 1
        sent_presses.append(presses)

    word_presses = []
    for si, sent in enumerate(sentences):
        sent_dist = abs(si - start_sent)
        n_words = len(sent)
        word_bisect = math.ceil(math.log2(max(n_words, 1)))
        # sent_nav + X (word mode) + bisect + A
        presses = sent_dist + 1 + word_bisect + 1
        word_presses.append(presses)

    return Result(
        name="Sentence nav + word bisection (hybrid)",
        description="Up/Down for sentences. X = word mode, LB/RB bisects words.\n"
                    "    Best of both: structure-aware + logarithmic.",
        avg_word=statistics.mean(word_presses),
        avg_sentence=statistics.mean(sent_presses),
        worst_word=max(word_presses),
        worst_sentence=max(sent_presses),
        total_buttons=7,  # Up, Down, LB, RB, A, X
    )


def _split_sentences(text):
    """Rough sentence splitter for the analysis."""
    import re
    parts = re.split(r'(?<=[.!?])\s+', text.strip())
    return [p for p in parts if p]


# ── Run analysis ────────────────────────────────────────────────────

def main():
    words, sentences, lines = build_page()

    print("=" * 72)
    print("KoPad: Gamepad Text Selection — Method Comparison")
    print("=" * 72)
    print(f"\nPage stats: {len(words)} words, {len(sentences)} sentences, "
          f"{len(lines)} lines, {len(PAGE_TEXT.strip().split(chr(10)+chr(10)))} paragraphs")
    print(f"Avg sentence length: {statistics.mean(len(s) for s in sentences):.1f} words")
    print(f"Avg line length: {statistics.mean(len(l) for l in lines):.1f} words")
    print()

    methods = [
        method_1_linear_scan,
        method_2_line_then_word,
        method_3_sentence_first,
        method_4_binary_bisect,
        method_5_crosshair,
        method_6_paragraph_sentence_word,
        method_7_numbered_labels,
        method_8_hybrid_sentence_bisect,
    ]

    results = [m(words, sentences, lines) for m in methods]

    # Print results table
    print(f"{'Method':<42} {'Avg W':>6} {'Avg S':>6} {'Max W':>6} {'Max S':>6} {'Btns':>5}")
    print("-" * 72)
    for r in results:
        print(f"{r.name:<42} {r.avg_word:>6.1f} {r.avg_sentence:>6.1f} "
              f"{r.worst_word:>6} {r.worst_sentence:>6} {r.total_buttons:>5}")

    print()
    print("=" * 72)
    print("DETAILED METHOD DESCRIPTIONS")
    print("=" * 72)
    for r in results:
        print(f"\n  [{r.total_buttons} buttons]  {r.name}")
        print(f"    {r.description}")
        print(f"    → Word:     avg {r.avg_word:.1f} presses, worst {r.worst_word}")
        print(f"    → Sentence: avg {r.avg_sentence:.1f} presses, worst {r.worst_sentence}")

    # Rank by combined score (weighted: sentence selection 60%, word 40%)
    print()
    print("=" * 72)
    print("RANKING (60% sentence weight, 40% word weight)")
    print("=" * 72)
    ranked = sorted(results, key=lambda r: 0.6 * r.avg_sentence + 0.4 * r.avg_word)
    for i, r in enumerate(ranked, 1):
        score = 0.6 * r.avg_sentence + 0.4 * r.avg_word
        print(f"  {i}. {r.name:<42} score={score:.1f}  (S:{r.avg_sentence:.1f} W:{r.avg_word:.1f})")

    print()
    print("=" * 72)
    print("RECOMMENDATION FOR KOPAD")
    print("=" * 72)
    print("""
  Primary mode: Sentence → Word (visel-style, Method 3)
  - Familiar from keyreader, maps naturally to D-pad
  - Up/Down = sentence, Left/Right = word (after entering word mode)
  - Best average sentence selection (most common operation when reading)

  Enhancement: Add binary word bisection (Method 8) as optional turbo:
  - LB/RB bisects words within sentence for faster word targeting
  - Cuts worst-case word selection from ~20 to ~7 presses

  Bonus: Paragraph jump via LT/RT (from Method 6):
  - LT/RT jumps to previous/next paragraph
  - Reduces sentence navigation distance on long pages

  Proposed gamepad mapping:
    D-pad Up/Down     Sentence navigation
    D-pad Left/Right  Word navigation (in word mode)
    A                 Confirm / select
    B                 Cancel / back
    X                 Enter word mode / dictionary lookup
    Y                 Copy / yank
    LB / RB           Page turn (or word bisect in word mode)
    LT / RT           Paragraph jump
    L-stick           (future: crosshair for direct pointing)
    R-stick           Scroll page
    Start             Menu
    Select            Toggle overlay / visel mode
""")


if __name__ == "__main__":
    main()
