"""brain_stem - tiny rule-based suffix stripper, tuned for Turkish agglutinative endings.

Why it exists: BM25 matches tokens literally, so a Turkish query word carrying case/possessive
suffixes never matches the note slug it refers to. Stripping the longest known suffix recovers
that match (ciroyu -> ciro). Not a linguistically correct stemmer (no vowel harmony, no
allomorphy) - it is a recall aid. English tokens are mostly left alone because the short-root
guard below (>=3 chars must remain, tokens <=4 chars untouched) keeps common words intact.

Zero dependencies. Expects de-accented lowercase tokens (see brain_bm25._TR).
"""

# Suffix list in de-accented form, LONGEST -> SHORTEST (only the longest match is stripped).
_SUF = (
    "larindan", "lerinden", "lariyla", "leriyle", "larina", "lerine", "larini", "lerini",
    "lardan", "lerden", "larda", "lerde", "larin", "lerin", "lari", "leri", "lar", "ler",
    "yorum", "yoruz", "iyor", "yor", "maktan", "mekten", "mali", "meli",
    "nin", "nun", "dan", "den", "tan", "ten", "deki", "daki", "ndan", "nden",
    "la", "le", "ya", "ye", "yu", "yi", "da", "de", "ta", "te", "in", "un",
    "si", "su", "ni", "nu", "i", "u", "e", "a",
)


def stem(t):
    if len(t) <= 4:
        return t                    # leave short roots alone
    for s in _SUF:
        if t.endswith(s) and len(t) - len(s) >= 3:
            return t[:-len(s)]
    return t
