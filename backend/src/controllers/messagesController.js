// WhatsApp-style messaging for the driver app: conversations + messages.
//
// DEMO behaviour: when the driver sends a message, the other party (dispatch /
// support / customer) sends a canned auto-reply so the inbox feels two-way
// without a separate dispatcher console. Real two-way chat would be driven by
// the admin dashboard / a customer app.

const pool = require("../config/db");

async function getDriverProfile(userId) {
  const result = await pool.query(
    `SELECT id FROM driver_profiles WHERE user_id = $1 LIMIT 1`,
    [userId]
  );
  return result.rows[0];
}

async function ownsConversation(driverId, conversationId) {
  const result = await pool.query(
    `SELECT id, party, title FROM conversations WHERE id = $1 AND driver_id = $2 LIMIT 1`,
    [conversationId, driverId]
  );
  return result.rows[0];
}

function formatMessage(row) {
  return {
    id: String(row.id),
    sender: row.sender,
    body: row.body,
    createdAt: row.created_at,
  };
}

async function getConversations(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const result = await pool.query(
    `
      SELECT
        c.id, c.party, c.title, c.updated_at,
        lm.body AS last_body,
        lm.sender AS last_sender,
        lm.created_at AS last_at,
        COALESCE(uc.unread, 0) AS unread
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT body, sender, created_at
        FROM messages m
        WHERE m.conversation_id = c.id
        ORDER BY m.created_at DESC
        LIMIT 1
      ) lm ON TRUE
      LEFT JOIN LATERAL (
        SELECT COUNT(*) AS unread
        FROM messages m
        WHERE m.conversation_id = c.id
          AND m.sender <> 'driver'
          AND m.read_by_driver = FALSE
      ) uc ON TRUE
      WHERE c.driver_id = $1
      ORDER BY c.updated_at DESC
    `,
    [driver.id]
  );

  const conversations = result.rows.map((row) => ({
    id: row.id,
    party: row.party,
    title: row.title,
    lastMessage: row.last_body,
    lastSender: row.last_sender,
    lastAt: row.last_at,
    unread: Number(row.unread),
  }));

  return res.json({ conversations });
}

async function getMessages(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const conversationId = Number(req.params.conversationId);
  const conversation = await ownsConversation(driver.id, conversationId);
  if (!conversation) return res.status(404).json({ message: "Conversation not found." });

  const result = await pool.query(
    `
      SELECT id, sender, body, created_at
      FROM messages
      WHERE conversation_id = $1
      ORDER BY created_at ASC
    `,
    [conversationId]
  );

  // Mark incoming messages as read.
  await pool.query(
    `UPDATE messages SET read_by_driver = TRUE
       WHERE conversation_id = $1 AND sender <> 'driver' AND read_by_driver = FALSE`,
    [conversationId]
  );

  return res.json({
    conversation: { id: conversation.id, party: conversation.party, title: conversation.title },
    messages: result.rows.map(formatMessage),
  });
}

function autoReply(party, title) {
  switch (party) {
    case "dispatch":
      return "Thanks, noted. Dispatch is on it — we'll update you shortly.";
    case "support":
      return "Thanks for reaching out. A Stan support agent will follow up here.";
    case "customer":
      return `This is ${title}. Got it, thank you — see you soon!`;
    default:
      return "Message received.";
  }
}

async function sendMessage(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const conversationId = Number(req.params.conversationId);
  const body = String(req.body.body || "").trim();

  if (!body) return res.status(400).json({ message: "Message cannot be empty." });
  if (body.length > 2000) return res.status(400).json({ message: "Message is too long." });

  const conversation = await ownsConversation(driver.id, conversationId);
  if (!conversation) return res.status(404).json({ message: "Conversation not found." });

  const inserted = [];

  const driverMsg = await pool.query(
    `
      INSERT INTO messages (conversation_id, sender, body, read_by_driver)
      VALUES ($1, 'driver', $2, TRUE)
      RETURNING id, sender, body, created_at
    `,
    [conversationId, body]
  );
  inserted.push(formatMessage(driverMsg.rows[0]));

  // DEMO auto-reply from the other party.
  const reply = await pool.query(
    `
      INSERT INTO messages (conversation_id, sender, body, read_by_driver)
      VALUES ($1, $2, $3, TRUE)
      RETURNING id, sender, body, created_at
    `,
    [conversationId, conversation.party, autoReply(conversation.party, conversation.title)]
  );
  inserted.push(formatMessage(reply.rows[0]));

  await pool.query(`UPDATE conversations SET updated_at = NOW() WHERE id = $1`, [conversationId]);

  return res.status(201).json({ messages: inserted });
}

module.exports = {
  getConversations,
  getMessages,
  sendMessage,
};
