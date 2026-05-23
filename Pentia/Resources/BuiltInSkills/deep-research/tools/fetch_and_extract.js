const META = {
  name: "fetch_and_extract",
  description: "Fetch a URL and extract readable text content. May fail due to sandbox CORS restrictions — use browser_navigate + browser_get_page_info as a reliable alternative.",
  parameters: [
    { name: "url",        type: "string", required: true,  description: "The URL to fetch content from" },
    { name: "max_length", type: "number", required: false, description: "Maximum characters to return (default: 5000)" }
  ]
};

const url = args.url;
const maxLen = args.max_length || 5000;
try {
    const resp = fetch(url);
    if (!resp.ok) {
        console.log(`[Error] HTTP ${resp.status}: ${resp.statusText}. Tip: use browser_navigate("${url}") + browser_get_page_info(include_content: true) instead.`);
    } else {
        const html = resp.text;
        const text = html
            .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
            .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
            .replace(/<nav[^>]*>[\s\S]*?<\/nav>/gi, '')
            .replace(/<header[^>]*>[\s\S]*?<\/header>/gi, '')
            .replace(/<footer[^>]*>[\s\S]*?<\/footer>/gi, '')
            .replace(/<[^>]+>/g, ' ')
            .replace(/&nbsp;/g, ' ')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&quot;/g, '"')
            .replace(/&#39;/g, "'")
            .replace(/\s+/g, ' ')
            .trim();
        console.log(text.substring(0, maxLen));
    }
} catch (e) {
    console.log(`[Error] Failed to fetch: ${e.message}. Tip: use browser_navigate("${url}") + browser_get_page_info(include_content: true) instead.`);
}
