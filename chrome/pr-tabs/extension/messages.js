// The runtime message contract between popup.js and background.js.

export const NO_ANSWER = "No answer from the PR tabs service worker. Reload the extension at chrome://extensions.";

// An onMessage listener that answers every message through sendResponse and keeps the channel open.
export function messageListener(handlers) {
  return (message, _sender, sendResponse) => {
    const type = message?.type;
    if (!Object.hasOwn(handlers, type)) {
      sendResponse({ error: `Unknown message type ${JSON.stringify(type)}. Reload the extension at chrome://extensions.` });
      return false;
    }
    Promise.resolve()
      .then(() => handlers[type](message))
      .then(
        (result) => sendResponse(result ?? {}),
        (error) => sendResponse({ error: error?.message || String(error) }),
      );
    return true;
  };
}

// Messages whose handler has side effects a second delivery would repeat.
export const NOT_RETRIED = new Set(["openAll", "checkNow", "closeDuplicates"]);

// Sends message, retrying once when there is no answer or the send throws, unless NOT_RETRIED; failures come back as { error }.
export async function ask(send, message) {
  let failure = NO_ANSWER;
  const attempts = NOT_RETRIED.has(message?.type) ? 1 : 2;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const reply = await send(message);
      if (reply !== undefined && reply !== null) return reply;
      failure = NO_ANSWER;
    } catch (error) {
      failure = error?.message || String(error);
    }
  }
  return { error: failure };
}
