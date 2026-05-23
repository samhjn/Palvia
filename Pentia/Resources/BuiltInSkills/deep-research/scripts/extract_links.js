// Extract links from HTML content (supports both single and double quoted href attributes)

const html = args.html || '';
const matches = [...html.matchAll(/<a[^>]+href=["']([^"']+)["'][^>]*>([^<]*)<\/a>/gi)];
const links = matches
    .map(m => ({ url: m[1], text: m[2].trim() }))
    .filter(l => l.url.startsWith('http') && l.text.length > 0);
const unique = links.filter((l, i, arr) => arr.findIndex(x => x.url === l.url) === i);
console.log(JSON.stringify(unique.slice(0, 30), null, 2));
