# Migrations

Numbered SQL files applied once each, in filename order, by `npm run db:migrate`
(also run automatically when the server boots).

Rules:

- **Additive only.** Never `DROP TABLE`, `TRUNCATE`, or rewrite existing data.
  New columns must have defaults or be nullable so existing rows stay valid.
- Name files `NNN_short_description.sql` (e.g. `001_customer_role.sql`).
- Never edit a migration after it has been committed — add a new one instead.
- `schema.sql` is the frozen baseline; new schema changes go here, not there.
