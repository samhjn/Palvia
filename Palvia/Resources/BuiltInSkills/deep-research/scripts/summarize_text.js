// Extract key sentences from long text, ranked by position and length importance

const text = args.text || '';
const maxLen = args.max_length || 2000;
const sentences = text.split(/(?<=[.!?])\s+/).filter(s => s.trim().length > 20);
if (sentences.length === 0) { console.log(text.substring(0, maxLen)); }
else {
    const scored = sentences.map((s, i) => ({
        text: s.trim(),
        score: (1 / (i + 1)) + Math.min(s.length / 200, 1)
    }));
    scored.sort((a, b) => b.score - a.score);
    const top = scored.slice(0, 15);
    top.sort((a, b) => {
        const ai = sentences.findIndex(x => x.includes(a.text));
        const bi = sentences.findIndex(x => x.includes(b.text));
        return ai - bi;
    });
    console.log(top.map(s => s.text).join(' ').substring(0, maxLen));
}
