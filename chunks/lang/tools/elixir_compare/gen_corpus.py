#!/usr/bin/env python3
"""Write the comparison corpus: one `label<TAB>hex` line per string.

    python3 gen_corpus.py <ucd_dir> > corpus.tsv

Hex, because some of the strings hold CR, LF and bytes that are not UTF-8.
<ucd_dir> is the one gen_unicode_tables.py read: its UnicodeData.txt says
which code points are assigned, and its GraphemeBreakTest.txt is replayed.
"""
import os
import sys
import unicodedata

ucd = sys.argv[1]
rows = []


def add(label, s):
    b = s if isinstance(s, bytes) else s.encode("utf-8")
    rows.append((label, b.hex()))


assigned = []
with open(os.path.join(ucd, "UnicodeData.txt"), encoding="utf-8") as f:
    first = None
    for line in f:
        fields = line.split(";")
        cp = int(fields[0], 16)
        name = fields[1]
        if name.endswith("First>"):
            first = cp
            continue
        if name.endswith("Last>"):
            assigned.extend(range(first, cp + 1))
            continue
        assigned.append(cp)
assigned = [c for c in assigned if not (0xD800 <= c <= 0xDFFF)]

for s in ["", "a", "hello", "Hello, World!", "tab\there", "line\nbreak", "a\r\nb", "\r\n", "\n\r", "x\ry"]:
    add("ascii", s)

emoji = "😀 😂 🥲 😍 🤔 🙃 👍 👋 🙏 💯 🔥 ✨ 🎉 🚀 🌍 🍰 🐍 🦀 🧠 ⭐ ☕ ⚡ ✅ ❌ ☺ ☹ ✌ ☝ ♥ ❤ ✈ ⌚ © ® ™ 〰 🀄 🅰 🈚".split()
for e in emoji:
    add("emoji", e)
    add("emoji+FE0F", e + "️")
    add("emoji+FE0E", e + "︎")
for k in "#*0123456789":
    add("keycap", k + "️⃣")
for hand in ["👍", "👋", "✌", "🤞", "🙌", "👩"]:
    for tone in range(0x1F3FB, 0x1F400):
        add("skin tone", hand + chr(tone))
zwj = [
    "👨‍👩‍👧‍👦", "👩‍👩‍👦", "👨‍👨‍👧‍👧", "👩‍💻", "👨🏽‍🚀", "🧑🏿‍🔬", "🏳️‍🌈", "🏴‍☠️", "👁️‍🗨️",
    "❤️‍🔥", "❤️‍🩹", "🐻‍❄️", "👩‍❤️‍💋‍👨", "🫱🏻‍🫲🏿", "🧑‍🤝‍🧑", "👨‍👩‍👧‍👦👨‍👩‍👧", "🏃🏽‍♀️‍➡️",
    "a‍b", "👨‍", "‍👨", "👨‍‍👩", "👨‍a", "🇺‍🇸", "😀́‍😀",
]
for s in zwj:
    add("ZWJ", s)
flags = ["🇺🇸", "🇫🇷", "🇩🇪", "🇯🇵", "🇧🇷", "🇺🇦", "🇮🇳", "🇨🇦", "🇬🇧", "🇰🇷", "🇪🇺", "🇺🇳"]
for fl in flags:
    add("flag", fl)
for i in range(len(flags) - 1):
    add("flags", flags[i] + flags[i + 1])
add("flags", "".join(flags))
for n in (1, 3, 5):
    add("odd RI", "🇦" * n)
add("RI+x", "🇦x🇧🇨🇩")
add("tag flag", "🏴󠁧󠁢󠁥󠁮󠁧󠁿")
add("tag flag", "🏴󠁧󠁢󠁳󠁣󠁴󠁿 🏴󠁧󠁢󠁷󠁬󠁳󠁿")

comb = [
    "é", "ǟ", "ño", "Z̴̡̪̫͎̦̬̬̓̓̐̋ä̸͉̥̝̋l̵̢̛̞̫̓g̷̯̈́o̵͍̍", "́", "́́a",
    "שָׁלוֹם", "مَرْحَبًا", "สวัสดีครับ", "नमस्ते", "क्षत्रिय", "স্ত্রী", "தமிழ்", "ಕನ್ನಡ", "ພາສາລາວ",
    "ཀྵ", "မြန်မာ", "ᄀᄀᄀ각ᆨᆨ", "각", "ｶﾞｷﾞ", "が", "が",
]
for s in comb:
    add("combining", s)
for s in ["Tiếng Việt", "naïve résumé", "Crème brûlée", "Ångström", "Łódź", "Dvořák"]:
    add("NFC", unicodedata.normalize("NFC", s))
    add("NFD", unicodedata.normalize("NFD", s))
for s in ["日本語のテキスト", "中文字符", "한국어", unicodedata.normalize("NFD", "한국어"), "𠜎𠜱𠝹", "ＡＢＣ", "ｱｲｳ"]:
    add("CJK", s)

case = [
    "İstanbul", "ıi Iİ", "DİYARBAKIR", "Straße", "STRASSE", "ẞ", "ß", "ΣΊΣΥΦΟΣ", "ὈΔΥΣΣΕΎΣ", "ᾳ ᾼ ᾀ ᾈ",
    "ΐ ΰ", "ς", "Москва", "ЁЛКА ёлка", "Ѣ ѣ Ѳ", "Ӂ ӂ", "Ꙁ ꙁ", "Армения", "և", "ﬓ", "ქართული", "ᲥᲐᲠᲗᲣᲚᲘ",
    "Ꭰꭰ ᏸ", "ǅǈǋǲ", "ǆǉǌǳ", "ŉ ǰ ẖ ẗ ẘ ẙ ẚ", "ﬀﬁﬂﬃﬄﬅﬆ", "𐐀𐐨 Deseret", "𞤀𞤢 Adlam", "Ⰰⰰ Glagolitic",
    "ⓐⓑⓒ ⒶⒷⒸ", "Ⅰ ⅰ", "µ ſ ı K Å", "ǰ̌", "ȺȾ ⱥⱦ", "Ɐ ɐ Ɑ ɑ", "ꞵ Ꞵ", "𑢠𑢿", "𖹀𖹠",
]
for s in case:
    add("case", s)
for s in ["I ❤️ Blimp!", "Café crème 🍰", "lol 😂😂😂", "👍🏽 +1 from me", "Ok👌🏼", "Ωmega and αlpha", "ПРИВЕТ мир"]:
    add("comment", s)

for lo, hi, label in [(0xC0, 0x24F, "Latin-1/Ext-A/B"), (0x370, 0x3FF, "Greek"), (0x400, 0x4FF, "Cyrillic"),
                      (0x1E00, 0x1EFF, "Latin Ext Additional"), (0x1F00, 0x1FFF, "Greek Extended")]:
    for c in assigned:
        if lo <= c <= hi:
            add(label, chr(c))

# Every assigned scalar value, 2048 to a row, in code point order.
for i in range(0, len(assigned), 2048):
    add("all code points", "".join(chr(c) for c in assigned[i:i + 2048]))

with open(os.path.join(ucd, "GraphemeBreakTest.txt"), encoding="utf-8") as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        add("GraphemeBreakTest", "".join(chr(int(t, 16)) for t in line.split() if t not in ("÷", "×")))

for b in [b"\xff", b"a\xffb", b"\xe2\x9d", b"\xe2\x9da\xf0\x80\x80", b"\xed\xa0\x80", b"\xc0\xaf", b"\xf4\x90\x80\x80",
          b"\xf0\x9f\x91", "héllo".encode()[:2], "❤️".encode()[:5], b"\x80\x80", b"a\xed\xa0\x80b\xf4\x80\x80c\xc0\x80d"]:
    add("invalid", b)

for label, h in rows:
    print(f"{label}\t{h}")
