const DB_NAME = "book-collector-pwa";
const DB_VERSION = 2;
const STORE_NAME = "books";

const CSV_COLUMNS = [
  "书号类型", "ISBN", "统一书号", "自定义书号", "书名", "原名", "丛书名", "作者", "作者国籍",
  "出版时间", "出版社", "收藏状态", "已买阅读标签", "未买阅读标签", "录入方式", "封面链接", "添加时间", "分类时间", "待定开始时间"
];

let db;
let books = [];
let selectedCategory = "owned";
let ownedFilter = "unread";
let wantToReadFilter = "unpurchased";
let sortOrder = "desc";
let editingBookId = null;
let coverDraft = "";
let scanStream = null;
let scanTimer = null;
let zxingControls = null;
let choiceResolve = null;

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function normalizeISBN(value = "") {
  return String(value).toUpperCase().replace(/[^0-9X]/g, "");
}

function nowISO() {
  return new Date().toISOString();
}

function shortDate(value) {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) return "";
  return `${String(date.getFullYear()).slice(2)}.${String(date.getMonth() + 1).padStart(2, "0")}.${String(date.getDate()).padStart(2, "0")}`;
}

function primaryIdentifier(book) {
  if (book.identifierKind === "统一书号") return (book.unifiedNumber || "").trim();
  if (book.identifierKind === "自定义书号") return (book.customNumber || "").trim();
  return normalizeISBN(book.isbn || book.identifier || "");
}

function normalizeBook(book = {}) {
  const next = {
    identifierKind: "ISBN",
    identifier: "",
    isbn: "",
    unifiedNumber: "",
    customNumber: "",
    title: "",
    originalTitle: "",
    seriesTitle: "",
    authors: "",
    authorNationality: "",
    publicationDate: "",
    publisher: "",
    ownershipStatus: "已买",
    ownedReadingStatus: "未读",
    wishlistReadingStatus: "想读",
    entrySource: "手写导入",
    coverData: "",
    coverUrl: "",
    createdAt: nowISO(),
    categoryDate: "",
    pendingSince: "",
    doubanSubjectID: "",
    doubanSubjectURL: "",
    ...book
  };
  if (next.identifierKind === "ISBN") next.isbn = normalizeISBN(next.isbn || next.identifier);
  next.identifier = primaryIdentifier(next);
  if (next.ownershipStatus === "未买" && next.wishlistReadingStatus === "待定") {
    next.pendingSince = next.pendingSince || nowISO();
  } else {
    next.pendingSince = "";
  }
  return next;
}

function matchingKeys(book) {
  const keys = [];
  const identifier = primaryIdentifier(book).toLowerCase();
  if (identifier) keys.push(`${book.identifierKind}:${identifier}`);
  if (book.doubanSubjectID) keys.push(`douban:${String(book.doubanSubjectID).trim().toLowerCase()}`);
  if (book.title) keys.push(`title:${book.title.trim().toLowerCase()}`);
  return keys;
}

function pendingDaysRemaining(book) {
  if (book.ownershipStatus !== "未买" || book.wishlistReadingStatus !== "待定") return null;
  const start = new Date(book.pendingSince || book.createdAt || nowISO());
  const days = Math.ceil((start.getTime() + 30 * 86400000 - Date.now()) / 86400000);
  return Math.max(days, 0);
}

function sortDate(book) {
  const date = new Date(book.categoryDate || book.createdAt || 0);
  return Number.isNaN(date.getTime()) ? 0 : date.getTime();
}

function buildSnapshot() {
  const owned = books.filter((book) => book.ownershipStatus === "已买");
  const ownedKeys = new Set(owned.flatMap(matchingKeys));
  const counts = {
    owned: owned.length,
    wantToRead: 0,
    unownedRead: 0,
    ownedRead: 0,
    ownedUnread: 0,
    wantPurchased: 0,
    wantUnpurchased: 0
  };

  for (const book of books) {
    if (book.ownershipStatus === "已买") {
      if (book.ownedReadingStatus === "已读") counts.ownedRead += 1;
      else {
        counts.ownedUnread += 1;
        counts.wantPurchased += 1;
      }
    } else if (book.wishlistReadingStatus === "想读") {
      counts.wantUnpurchased += 1;
    } else if (book.wishlistReadingStatus === "已读" && !matchingKeys(book).some((key) => ownedKeys.has(key))) {
      counts.unownedRead += 1;
    }
  }
  counts.wantToRead = counts.wantPurchased + counts.wantUnpurchased;
  return { counts, ownedKeys };
}

function categoryMatches(book, snapshot) {
  if (selectedCategory === "owned") return book.ownershipStatus === "已买" && book.ownedReadingStatus === (ownedFilter === "read" ? "已读" : "未读");
  if (selectedCategory === "wantToRead") {
    if (wantToReadFilter === "purchased") return book.ownershipStatus === "已买" && book.ownedReadingStatus === "未读";
    return book.ownershipStatus === "未买" && book.wishlistReadingStatus === "想读";
  }
  return book.ownershipStatus === "未买" &&
    book.wishlistReadingStatus === "已读" &&
    !matchingKeys(book).some((key) => snapshot.ownedKeys.has(key));
}

function filteredBooks(snapshot) {
  const query = $("#searchInput").value.trim().toLowerCase();
  return books
    .filter((book) => {
      if (!categoryMatches(book, snapshot)) return false;
      if (!query) return true;
      const haystack = [book.title, book.originalTitle, book.seriesTitle, book.authors, book.publisher, primaryIdentifier(book)].join(" ").toLowerCase();
      return haystack.includes(query);
    })
    .sort((a, b) => sortOrder === "desc" ? sortDate(b) - sortDate(a) : sortDate(a) - sortDate(b));
}

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(STORE_NAME)) {
        database.createObjectStore(STORE_NAME, { keyPath: "id", autoIncrement: true });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function txStore(mode = "readonly") {
  return db.transaction(STORE_NAME, mode).objectStore(STORE_NAME);
}

function getAllBooks() {
  return new Promise((resolve, reject) => {
    const request = txStore().getAll();
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
}

function putBook(book) {
  return new Promise((resolve, reject) => {
    const request = txStore("readwrite").put(book);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function deleteBook(id) {
  return new Promise((resolve, reject) => {
    const request = txStore("readwrite").delete(id);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

function validateBook(book) {
  const identifier = primaryIdentifier(book);
  if (!identifier) throw new Error("必须填写 ISBN、统一书号或自定义书号之一。");
  const duplicate = books.some((other) =>
    other.id !== book.id &&
    other.identifierKind === book.identifierKind &&
    primaryIdentifier(other).toLowerCase() === identifier.toLowerCase()
  );
  if (duplicate) throw new Error(`书号“${identifier}”已经存在，不能重复录入。`);
  if (book.ownershipStatus === "已买" && book.entrySource === "手写导入" && !book.coverData && !book.coverUrl) {
    throw new Error("手写导入已买图书时，需要添加封面照片。");
  }
}

async function saveBook(book) {
  const normalized = normalizeBook(book);
  validateBook(normalized);
  await putBook(normalized);
  await refresh();
}

async function importBook(book) {
  const normalized = normalizeBook(book);
  const existing = books.find((other) => matchingKeys(other).some((key) => matchingKeys(normalized).includes(key)));
  if (existing?.ownershipStatus === "已买" && normalized.ownershipStatus === "未买") return;
  await putBook(existing ? { ...normalized, id: existing.id } : normalized);
}

async function cleanupExpiredPendingBooks() {
  const expired = books.filter((book) => {
    if (book.ownershipStatus !== "未买" || book.wishlistReadingStatus !== "待定") return false;
    const start = new Date(book.pendingSince || book.createdAt || nowISO());
    return start.getTime() + 30 * 86400000 < Date.now();
  });
  await Promise.all(expired.map((book) => deleteBook(book.id)));
}

async function refresh() {
  books = (await getAllBooks()).map(normalizeBook);
  await cleanupExpiredPendingBooks();
  books = (await getAllBooks()).map(normalizeBook);
  render();
}

function render() {
  const snapshot = buildSnapshot();
  renderCategories(snapshot);
  renderBooks(filteredBooks(snapshot));
}

function renderCategories(snapshot) {
  $$(".category-tab").forEach((button) => {
    const key = button.dataset.category;
    button.classList.toggle("active", key === selectedCategory);
    button.querySelector("span").textContent = snapshot.counts[key] || 0;
  });
  $("#ownedSubfilters").hidden = selectedCategory !== "owned";
  $("#wantSubfilters").hidden = selectedCategory !== "wantToRead";
  $("#ownedReadCount").textContent = snapshot.counts.ownedRead;
  $("#ownedUnreadCount").textContent = snapshot.counts.ownedUnread;
  $("#wantPurchasedCount").textContent = snapshot.counts.wantPurchased;
  $("#wantUnpurchasedCount").textContent = snapshot.counts.wantUnpurchased;
  $$("#ownedSubfilters .sub-tab").forEach((button) => button.classList.toggle("active", button.dataset.ownedFilter === ownedFilter));
  $$("#wantSubfilters .sub-tab").forEach((button) => button.classList.toggle("active", button.dataset.wantFilter === wantToReadFilter));
  $("#sortButton").textContent = sortOrder === "desc" ? "时间降序 ↓" : "时间升序 ↑";
}

function coverSource(book) {
  return book.coverData || book.coverUrl || "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='160'%3E%3Crect width='120' height='160' fill='%23ececf1'/%3E%3Cpath d='M38 42h44v76H38z' fill='none' stroke='%23999' stroke-width='6'/%3E%3Cpath d='M48 54h25M48 68h25M48 82h25' stroke='%23999' stroke-width='4'/%3E%3C/svg%3E";
}

function rowStatus(book) {
  if (selectedCategory === "owned") return book.ownedReadingStatus;
  if (selectedCategory === "wantToRead") return book.ownershipStatus === "已买" ? "已购" : "未购买";
  return "已读";
}

function renderBooks(visible) {
  const list = $("#bookList");
  list.innerHTML = "";
  if (!visible.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "还没有图书，可以扫码、CSV/XLSX 导入，或手写录入第一本书。";
    list.append(empty);
    return;
  }

  const template = $("#bookCardTemplate");
  visible.forEach((book) => {
    const node = template.content.cloneNode(true);
    const cover = node.querySelector(".cover");
    cover.src = coverSource(book);
    cover.classList.toggle("placeholder", !book.coverData && !book.coverUrl);
    node.querySelector(".book-title").textContent = book.title || "未命名图书";
    node.querySelector(".authors").textContent = book.authors || "";
    node.querySelector(".publisher").textContent = book.publisher || "";
    node.querySelector(".identifier").textContent = `${book.identifierKind} ${primaryIdentifier(book)}`;
    node.querySelector(".added-date").textContent = shortDate(book.categoryDate || book.createdAt);
    const pending = pendingDaysRemaining(book);
    node.querySelector(".pending-days").textContent = pending == null ? "" : `${pending}天后删除`;

    const ownership = node.querySelector(".ownership-chip");
    ownership.textContent = book.ownershipStatus === "已买" ? "已购" : "未买";
    ownership.classList.toggle("active", book.ownershipStatus === "已买");
    ownership.addEventListener("click", () => changeOwnership(book));

    const reading = node.querySelector(".reading-chip");
    reading.textContent = rowStatus(book);
    reading.classList.toggle("active", rowStatus(book) !== "未读");
    reading.addEventListener("click", () => changeReading(book));

    node.querySelector(".cover-button").addEventListener("click", () => openForm(book));
    node.querySelector(".book-title").addEventListener("click", () => openForm(book));
    list.append(node);
  });
}

async function changeOwnership(book) {
  const next = await chooseOption("收藏状态", ["已买", "未买"], book.ownershipStatus);
  if (!next) return;
  const updated = { ...book, ownershipStatus: next };
  if (next === "已买") updated.ownedReadingStatus = "未读";
  if (next === "未买") updated.wishlistReadingStatus = "想读";
  try {
    await saveBook(updated);
  } catch (error) {
    alert(error.message);
  }
}

async function changeReading(book) {
  const current = book.ownershipStatus === "已买" ? book.ownedReadingStatus : book.wishlistReadingStatus;
  const choices = book.ownershipStatus === "已买" ? ["已读", "未读"] : ["已读", "想读", "待定"];
  const next = await chooseOption("阅读标签", choices, current);
  if (!next) return;
  const updated = { ...book };
  if (book.ownershipStatus === "已买") updated.ownedReadingStatus = next;
  else updated.wishlistReadingStatus = next;
  try {
    await saveBook(updated);
  } catch (error) {
    alert(error.message);
  }
}

function chooseOption(title, options, current) {
  $("#choiceTitle").textContent = title;
  const container = $("#choiceOptions");
  container.innerHTML = "";
  options.forEach((option) => {
    const button = document.createElement("button");
    button.className = `choice-option${option === current ? " active" : ""}`;
    button.textContent = option;
    button.addEventListener("click", () => {
      $("#choiceDialog").close();
      choiceResolve?.(option);
      choiceResolve = null;
    });
    container.append(button);
  });
  $("#choiceDialog").showModal();
  return new Promise((resolve) => { choiceResolve = resolve; });
}

function readFileAsDataURL(fileOrBlob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result || "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(fileOrBlob);
  });
}

function fillForm(book = {}) {
  const form = $("#bookForm");
  form.identifierKind.value = book.identifierKind || "ISBN";
  form.isbn.value = book.isbn || "";
  form.unifiedNumber.value = book.unifiedNumber || "";
  form.customNumber.value = book.customNumber || "";
  form.title.value = book.title || "";
  form.originalTitle.value = book.originalTitle || "";
  form.seriesTitle.value = book.seriesTitle || "";
  form.authors.value = book.authors || "";
  form.authorNationality.value = book.authorNationality || "";
  form.publicationDate.value = book.publicationDate || "";
  form.publisher.value = book.publisher || "";
  form.ownershipStatus.value = book.ownershipStatus || "已买";
  form.ownedReadingStatus.value = book.ownedReadingStatus || "未读";
  form.wishlistReadingStatus.value = book.wishlistReadingStatus || "想读";
  form.entrySource.value = book.entrySource || "手写导入";
  form.coverUrl.value = book.coverUrl || "";
  coverDraft = book.coverData || "";
  $("#coverPreview").src = coverDraft || book.coverUrl || "";
  $("#coverPreview").style.display = (coverDraft || book.coverUrl) ? "block" : "none";
}

function formBook() {
  const form = $("#bookForm");
  const existing = editingBookId ? books.find((book) => book.id === editingBookId) : {};
  return {
    ...existing,
    identifierKind: form.identifierKind.value,
    isbn: form.isbn.value,
    unifiedNumber: form.unifiedNumber.value,
    customNumber: form.customNumber.value,
    title: form.title.value,
    originalTitle: form.originalTitle.value,
    seriesTitle: form.seriesTitle.value,
    authors: form.authors.value,
    authorNationality: form.authorNationality.value,
    publicationDate: form.publicationDate.value,
    publisher: form.publisher.value,
    ownershipStatus: form.ownershipStatus.value,
    ownedReadingStatus: form.ownedReadingStatus.value,
    wishlistReadingStatus: form.wishlistReadingStatus.value,
    entrySource: form.entrySource.value,
    coverData: coverDraft,
    coverUrl: form.coverUrl.value,
    createdAt: existing.createdAt || nowISO(),
    categoryDate: existing.categoryDate || nowISO(),
    pendingSince: existing.pendingSince || ""
  };
}

function openForm(book = null) {
  editingBookId = book?.id || null;
  $("#bookDialogTitle").textContent = editingBookId ? "编辑图书" : "录入图书";
  fillForm(book || {});
  $("#bookDialog").showModal();
}

function applyCurrentCategory(book) {
  const next = { ...book };
  if (selectedCategory === "owned") {
    next.ownershipStatus = "已买";
    next.ownedReadingStatus = ownedFilter === "read" ? "已读" : "未读";
    next.wishlistReadingStatus = "想读";
  } else if (selectedCategory === "wantToRead") {
    if (wantToReadFilter === "purchased") {
      next.ownershipStatus = "已买";
      next.ownedReadingStatus = "未读";
    } else {
      next.ownershipStatus = "未买";
      next.wishlistReadingStatus = "想读";
    }
  } else {
    next.ownershipStatus = "未买";
    next.wishlistReadingStatus = "已读";
  }
  return next;
}

async function lookupISBN(isbn) {
  const response = await fetch(`/api/lookup?isbn=${encodeURIComponent(normalizeISBN(isbn))}`);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || "没有查询到结果，请手动输入。");
  return payload.candidates || [];
}

async function handleISBN(isbn) {
  stopScan();
  $("#scanDialog").close();
  const cleanISBN = normalizeISBN(isbn);
  if (!cleanISBN) {
    alert("没有识别到有效 ISBN。");
    return;
  }
  try {
    const candidates = await lookupISBN(cleanISBN);
    const fallback = normalizeBook({ identifierKind: "ISBN", isbn: cleanISBN, title: `ISBN ${cleanISBN}`, sourceName: "仅保存 ISBN" });
    const selected = await chooseBookCandidate([...candidates, fallback]);
    if (!selected) return;
    await saveBook(applyCurrentCategory(normalizeBook({
      ...selected,
      entrySource: "扫码导入",
      createdAt: nowISO(),
      categoryDate: nowISO()
    })));
  } catch (error) {
    alert(`没有查询到结果，请手动输入。\n\n${error.message}`);
    openForm(applyCurrentCategory({ identifierKind: "ISBN", isbn: cleanISBN, entrySource: "扫码导入" }));
  }
}

function chooseBookCandidate(candidates) {
  $("#choiceTitle").textContent = "选择图书信息";
  const container = $("#choiceOptions");
  container.innerHTML = "";
  candidates.forEach((book) => {
    const button = document.createElement("button");
    button.className = "choice-option book-choice";
    button.innerHTML = `
      <img src="${coverSource(book)}" alt="">
      <span><strong>${book.title || "未命名图书"}</strong><small>${book.sourceName || ""}${book.authors ? ` · ${book.authors}` : ""}</small></span>
    `;
    button.addEventListener("click", () => {
      $("#choiceDialog").close();
      choiceResolve?.(book);
      choiceResolve = null;
    });
    container.append(button);
  });
  $("#choiceDialog").showModal();
  return new Promise((resolve) => { choiceResolve = resolve; });
}

async function startScan() {
  $("#scanDialog").showModal();
  $("#scanStatus").textContent = "请把 ISBN 条码或二维码对准摄像头。";
  if (window.ZXingBrowser?.BrowserMultiFormatReader) {
    await startZXingScan();
    return;
  }
  if (!("BarcodeDetector" in window)) {
    $("#scanStatus").textContent = "当前浏览器不支持直接扫码，请在下方手动输入 ISBN。";
    return;
  }
  try {
    scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
    const video = $("#scanVideo");
    video.srcObject = scanStream;
    await video.play();
    const detector = new BarcodeDetector({ formats: ["ean_13", "ean_8", "qr_code"] });
    scanTimer = window.setInterval(async () => {
      if (!video.videoWidth) return;
      const codes = await detector.detect(video).catch(() => []);
      const value = codes.map((code) => normalizeISBN(code.rawValue)).find((code) => code.length === 10 || code.length === 13);
      if (value) handleISBN(value);
    }, 550);
  } catch (error) {
    $("#scanStatus").textContent = `无法使用摄像头：${error.message}。请手动输入 ISBN。`;
  }
}

async function startZXingScan() {
  try {
    const video = $("#scanVideo");
    const codeReader = new window.ZXingBrowser.BrowserMultiFormatReader();
    zxingControls = await codeReader.decodeFromVideoDevice(undefined, video, (result) => {
      if (!result) return;
      const value = normalizeISBN(result.getText ? result.getText() : result.text);
      if (value.length === 10 || value.length === 13) handleISBN(value);
    });
    scanStream = video.srcObject;
    $("#scanStatus").textContent = "请把 ISBN 条码或二维码放进画面中央。";
  } catch (error) {
    $("#scanStatus").textContent = `无法使用摄像头：${error.message}。请手动输入 ISBN。`;
  }
}

function stopScan() {
  zxingControls?.stop();
  zxingControls = null;
  if (scanTimer) window.clearInterval(scanTimer);
  scanTimer = null;
  if (scanStream) scanStream.getTracks().forEach((track) => track.stop());
  scanStream = null;
  $("#scanVideo").srcObject = null;
}

function csvEscape(value = "") {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function toCSV(rows) {
  return [CSV_COLUMNS.join(","), ...rows.map((row) => CSV_COLUMNS.map((col) => csvEscape(row[col])).join(","))].join("\n");
}

function parseCSV(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (quoted) {
      if (ch === '"' && next === '"') {
        cell += '"';
        i += 1;
      } else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else if (ch !== "\r") cell += ch;
  }
  row.push(cell);
  rows.push(row);
  const headers = rows.shift() || [];
  return rows.filter((r) => r.some(Boolean)).map((r) => Object.fromEntries(headers.map((h, i) => [h.trim(), r[i] || ""])));
}

function bookToRow(book) {
  return {
    "书号类型": book.identifierKind,
    ISBN: book.isbn,
    "统一书号": book.unifiedNumber,
    "自定义书号": book.customNumber,
    "书名": book.title,
    "原名": book.originalTitle,
    "丛书名": book.seriesTitle,
    "作者": book.authors,
    "作者国籍": book.authorNationality,
    "出版时间": book.publicationDate,
    "出版社": book.publisher,
    "收藏状态": book.ownershipStatus,
    "已买阅读标签": book.ownedReadingStatus,
    "未买阅读标签": book.wishlistReadingStatus,
    "录入方式": book.entrySource,
    "封面链接": book.coverUrl || book.coverData,
    "添加时间": book.createdAt,
    "分类时间": book.categoryDate,
    "待定开始时间": book.pendingSince
  };
}

function rowToBook(row, fileName = "") {
  const coverUrl = row["封面链接"] || row.cover_url || row.coverURL || row.cover || "";
  const subjectID = row.subject_id || "";
  const status = row.status || "";
  const pub = parsePub(row.pub || "");
  let book = normalizeBook({
    identifierKind: row["书号类型"] || (row.ISBN ? "ISBN" : "自定义书号"),
    isbn: row.ISBN || row.isbn || "",
    unifiedNumber: row["统一书号"] || "",
    customNumber: row["自定义书号"] || subjectID || "",
    title: row["书名"] || row.title || "",
    originalTitle: row["原名"] || row.subtitle || "",
    seriesTitle: row["丛书名"] || "",
    authors: row["作者"] || pub.authors,
    authorNationality: row["作者国籍"] || "",
    publicationDate: row["出版时间"] || pub.publicationDate,
    publisher: row["出版社"] || pub.publisher,
    ownershipStatus: row["收藏状态"] || "已买",
    ownedReadingStatus: row["已买阅读标签"] || "未读",
    wishlistReadingStatus: row["未买阅读标签"] || "想读",
    entrySource: row["录入方式"] || "CSV/Excel导入",
    coverUrl,
    createdAt: row["添加时间"] || row.date || nowISO(),
    categoryDate: row["分类时间"] || row.date || nowISO(),
    pendingSince: row["待定开始时间"] || "",
    doubanSubjectID: subjectID,
    doubanSubjectURL: row.subject_url || ""
  });

  if (fileName.includes("未购已读") || fileName.includes("未买已读") || status.includes("读过")) {
    book.ownershipStatus = "未买";
    book.wishlistReadingStatus = "已读";
  } else if (fileName.includes("想读") || status.includes("想读")) {
    book.ownershipStatus = "未买";
    book.wishlistReadingStatus = "想读";
  }
  return normalizeBook(book);
}

function parsePub(value = "") {
  const parts = String(value).split(" / ").map((part) => part.trim()).filter(Boolean);
  const dateIndex = parts.findIndex((part) => /^\d{4}([-.年]\d{1,2}.*)?$/.test(part));
  if (dateIndex >= 0) {
    return {
      authors: parts.slice(0, Math.max(dateIndex - 1, 0)).join(" / "),
      publisher: dateIndex > 0 ? parts[dateIndex - 1] : "",
      publicationDate: parts[dateIndex]
    };
  }
  return { authors: parts.slice(0, -2).join(" / "), publisher: parts.at(-2) || "", publicationDate: parts.at(-1) || "" };
}

function exportCSV() {
  const blob = new Blob(["\ufeff" + toCSV(books.map(bookToRow))], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "藏书.csv";
  a.click();
  URL.revokeObjectURL(url);
}

async function importFile(file) {
  let rows = [];
  if (file.name.toLowerCase().endsWith(".xlsx")) {
    if (!window.XLSX) throw new Error("Excel 解析组件未加载，请先导出为 CSV 再导入。");
    const data = await file.arrayBuffer();
    const workbook = window.XLSX.read(data, { type: "array", cellDates: true });
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    rows = window.XLSX.utils.sheet_to_json(sheet, { defval: "" });
  } else {
    rows = parseCSV(await file.text());
  }
  for (const row of rows) {
    await importBook(rowToBook(row, file.name));
  }
  await refresh();
}

function wireEvents() {
  $$(".category-tab").forEach((button) => {
    button.addEventListener("click", () => {
      selectedCategory = button.dataset.category;
      render();
    });
  });
  $$("#ownedSubfilters .sub-tab").forEach((button) => {
    button.addEventListener("click", () => {
      ownedFilter = button.dataset.ownedFilter;
      render();
    });
  });
  $$("#wantSubfilters .sub-tab").forEach((button) => {
    button.addEventListener("click", () => {
      wantToReadFilter = button.dataset.wantFilter;
      render();
    });
  });
  $("#sortButton").addEventListener("click", () => {
    sortOrder = sortOrder === "desc" ? "asc" : "desc";
    render();
  });
  $("#moreButton").addEventListener("click", () => $("#moreDialog").showModal());
  $("#manualAddButton").addEventListener("click", () => {
    $("#moreDialog").close();
    openForm(applyCurrentCategory({ entrySource: "手写导入" }));
  });
  $("#importButton").addEventListener("click", () => $("#importFile").click());
  $("#exportButton").addEventListener("click", () => {
    $("#moreDialog").close();
    exportCSV();
  });
  $("#importFile").addEventListener("change", async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      await importFile(file);
      alert("导入完成。");
    } catch (error) {
      alert(`导入失败：${error.message}`);
    } finally {
      event.target.value = "";
      $("#moreDialog").close();
    }
  });
  $("#searchInput").addEventListener("input", render);
  $("#searchForm").addEventListener("submit", (event) => {
    event.preventDefault();
    render();
  });
  $("#bookForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      await saveBook(formBook());
      $("#bookDialog").close();
    } catch (error) {
      alert(error.message);
    }
  });
  $("#cancelBookButton").addEventListener("click", () => $("#bookDialog").close());
  $("#bookForm").coverFile.addEventListener("change", async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    coverDraft = await readFileAsDataURL(file);
    $("#coverPreview").src = coverDraft;
    $("#coverPreview").style.display = "block";
  });
  $("#scanButton").addEventListener("click", startScan);
  $("#cancelScanButton").addEventListener("click", () => {
    stopScan();
    $("#scanDialog").close();
  });
  $("#scanDialog").addEventListener("close", stopScan);
  $("#manualIsbnButton").addEventListener("click", () => handleISBN($("#manualIsbnInput").value));
  $("#cancelChoiceButton").addEventListener("click", () => {
    $("#choiceDialog").close();
    choiceResolve?.(null);
    choiceResolve = null;
  });
  $("#choiceDialog").addEventListener("close", () => {
    choiceResolve?.(null);
    choiceResolve = null;
  });
}

async function init() {
  db = await openDB();
  wireEvents();
  await refresh();
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("./sw.js").catch(() => {});
  }
}

init().catch((error) => {
  console.error(error);
  alert(`启动失败：${error.message}`);
});
