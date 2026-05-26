function clean(value = "") {
  return String(value)
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function firstMatch(pattern, text) {
  const match = text.match(pattern);
  return match ? clean(match[1]) : "";
}

function meta(text, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return (
    firstMatch(new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]+content=["']([^"']+)["'][^>]*>`, "is"), text) ||
    firstMatch(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${escaped}["'][^>]*>`, "is"), text)
  );
}

function doubanDetail(text, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return (
    firstMatch(new RegExp(`<span[^>]+class=["']pl["'][^>]*>\\s*${escaped}\\s*:?\\s*</span>\\s*:?\\s*(.*?)<br`, "is"), text) ||
    firstMatch(new RegExp(`<span[^>]+class=["']pl["'][^>]*>\\s*${escaped}\\s*：?\\s*</span>\\s*：?\\s*(.*?)<br`, "is"), text) ||
    firstMatch(new RegExp(`${escaped}\\s*[:：]\\s*([^<\\n]+)`, "is"), text)
  );
}

function cleanTitle(value) {
  return clean(value)
    .replace(" (豆瓣)", "")
    .replace("(豆瓣)", "")
    .replace(" | 豆瓣", "")
    .replace(" - 豆瓣", "")
    .trim();
}

export default async function handler(req, res) {
  const isbn = String(req.query.isbn || "").toUpperCase().replace(/[^0-9X]/g, "");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "s-maxage=86400, stale-while-revalidate=604800");

  if (!isbn) {
    res.status(400).json({ error: "ISBN 不正确，无法查询。" });
    return;
  }

  const url = `https://book.douban.com/isbn/${isbn}/`;
  try {
    const response = await fetch(url, {
      redirect: "follow",
      headers: {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Referer": "https://book.douban.com/"
      }
    });

    if (!response.ok) {
      res.status(response.status === 404 ? 404 : 502).json({ error: "没有查询到结果，请手动输入。", sourceUrl: url });
      return;
    }

    const text = await response.text();
    const title = cleanTitle(
      meta(text, "og:title") ||
      firstMatch(/<title>([^<]+)<\/title>/is, text) ||
      firstMatch(/<h1[^>]*>(.*?)<\/h1>/is, text)
    );

    if (!title) {
      res.status(404).json({ error: "没有查询到结果，请手动输入。", sourceUrl: url });
      return;
    }

    res.status(200).json({
      identifierKind: "ISBN",
      isbn,
      title,
      originalTitle: doubanDetail(text, "原作名"),
      seriesTitle: doubanDetail(text, "丛书"),
      authors: meta(text, "book:author") || doubanDetail(text, "作者"),
      authorNationality: "",
      publicationDate: doubanDetail(text, "出版年"),
      publisher: doubanDetail(text, "出版社"),
      coverUrl: meta(text, "og:image"),
      sourceUrl: url
    });
  } catch (error) {
    res.status(502).json({ error: `豆瓣图书查询失败：${error.message}`, sourceUrl: url });
  }
}
