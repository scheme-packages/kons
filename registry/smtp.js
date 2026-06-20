import net from "node:net";
import tls from "node:tls";

function encodeBase64(value) {
  return Buffer.from(String(value), "utf8").toString("base64");
}

function createLineReader(socket) {
  let buffer = "";
  const waiters = [];

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    while (true) {
      const index = buffer.indexOf("\r\n");
      if (index === -1) break;
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(line);
    }
  });

  socket.on("error", (error) => {
    while (waiters.length) waiters.shift().reject(error);
  });

  socket.on("close", () => {
    const error = new Error("SMTP connection closed");
    while (waiters.length) waiters.shift().reject(error);
  });

  return () => new Promise((resolve, reject) => {
    const index = buffer.indexOf("\r\n");
    if (index !== -1) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      resolve(line);
      return;
    }
    waiters.push({ resolve, reject });
  });
}

async function readResponse(readLine) {
  const lines = [];
  while (true) {
    const line = await readLine();
    lines.push(line);
    if (/^\d{3} /.test(line)) break;
  }
  const last = lines.at(-1);
  const code = Number(last.slice(0, 3));
  if (code >= 400) {
    throw new Error(`SMTP ${code}: ${last.slice(4)}`);
  }
  return lines.join("\n");
}

async function sendCommand(socket, readLine, command) {
  if (command) socket.write(`${command}\r\n`);
  return readResponse(readLine);
}

function connectSocket(host, port, secure) {
  return new Promise((resolve, reject) => {
    if (secure) {
      const socket = tls.connect({ host, port, servername: host }, () => resolve(socket));
      socket.on("error", reject);
      return;
    }
    const socket = net.connect({ host, port }, () => resolve(socket));
    socket.on("error", reject);
  });
}

function upgradeStartTls(socket, host) {
  return new Promise((resolve, reject) => {
    const secure = tls.connect({
      socket,
      servername: host,
    }, () => resolve(secure));
    secure.on("error", reject);
  });
}

export function smtpConfigured(config) {
  return Boolean(config.host && config.user && config.pass);
}

export async function sendMail(config, message) {
  const host = config.host;
  const port = Number(config.port || 587);
  const secure = config.secure || port === 465;
  const from = message.from || config.from || config.user;
  const to = message.to;
  const subject = message.subject || "";
  const text = message.text || "";

  let socket = await connectSocket(host, port, secure);
  const readLine = createLineReader(socket);

  try {
    await readResponse(readLine);
    await sendCommand(socket, readLine, `EHLO kons`);

    if (!secure && port === 587) {
      await sendCommand(socket, readLine, "STARTTLS");
      socket = await upgradeStartTls(socket, host);
      const secureReadLine = createLineReader(socket);
      await sendCommand(socket, secureReadLine, `EHLO kons`);
      await authAndSend(socket, secureReadLine, config, from, to, subject, text);
      await sendCommand(socket, secureReadLine, "QUIT");
      return;
    }

    await authAndSend(socket, readLine, config, from, to, subject, text);
    await sendCommand(socket, readLine, "QUIT");
  } finally {
    socket.end();
  }
}

async function authAndSend(socket, readLine, config, from, to, subject, text) {
  await sendCommand(socket, readLine, "AUTH LOGIN");
  await sendCommand(socket, readLine, encodeBase64(config.user));
  await sendCommand(socket, readLine, encodeBase64(config.pass));
  await sendCommand(socket, readLine, `MAIL FROM:<${from}>`);
  await sendCommand(socket, readLine, `RCPT TO:<${to}>`);
  await sendCommand(socket, readLine, "DATA");

  const body = [
    `From: ${from}`,
    `To: ${to}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "",
    text.replace(/\r?\n/g, "\r\n"),
  ].join("\r\n");

  socket.write(`${body}\r\n.\r\n`);
  await readResponse(readLine);
}
