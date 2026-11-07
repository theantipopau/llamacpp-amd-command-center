const port = process.argv[2] || "9345";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  let targets;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      break;
    } catch (error) {
      if (attempt === 79) throw error;
      await sleep(250);
    }
  }
  if (!targets) throw new Error("No WebView2 target list");
  const target = targets.find((item) => item.type === "page") || targets[0];
  if (!target || !target.webSocketDebuggerUrl) throw new Error("No WebView2 page target");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let nextId = 1;
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    }
  };
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error("WebSocket connection failed"));
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result?.value;
  };
  await send("Runtime.enable");
  const deadline = Date.now() + 20000;
  let ready = false;
  while (Date.now() < deadline) {
    ready = await evaluate("!!document.querySelector('[role=tablist]')");
    if (ready) break;
    await sleep(250);
  }
  if (!ready) throw new Error("UI did not become ready");
  const clicked = await evaluate(`(() => {
    const button = [...document.querySelectorAll('button')].find((item) => item.textContent.trim() === 'Open chat');
    if (!button) return false;
    button.click();
    return true;
  })()`);
  await sleep(1500);
  const status = await evaluate("[...document.querySelectorAll('[role=status]')].map((item) => item.textContent.trim()).filter(Boolean).slice(-3)");
  console.log(JSON.stringify({ clicked, status }));
  ws.close();
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
