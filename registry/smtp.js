import nodemailer from "nodemailer";

export function smtpConfigured(config) {
  return Boolean(config.host && config.user && config.pass);
}

export async function sendMail(config, message) {
  const port = Number(config.port || 587);
  const secure = Boolean(config.secure || port === 465);
  const from = message.from || config.from || config.user;

  const transporter = nodemailer.createTransport({
    host: config.host,
    port,
    secure,
    auth: {
      user: config.user,
      pass: config.pass,
    },
    connectionTimeout: Number(config.connectionTimeoutMs || 15000),
    greetingTimeout: Number(config.greetingTimeoutMs || 15000),
    socketTimeout: Number(config.socketTimeoutMs || 30000),
  });

  await transporter.sendMail({
    from,
    to: message.to,
    subject: message.subject || "",
    text: message.text || "",
  });
}
