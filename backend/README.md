# Logistics Backend

Node.js API for the logistics tracking system.

## Setup

```bash
npm install
copy .env.example .env
npm run dev
```

The API should run on:

```text
http://localhost:5000
```

Health check:

```text
http://localhost:5000/health
```

Database health check:

```text
http://localhost:5000/db-health
```

## Database Setup

```bash
npm run db:init
npm run db:seed
```

Development test accounts:

```text
Admin: 0700000000 / admin123
Driver: 0711111111 / driver123
```

Login endpoint:

```text
POST http://localhost:5000/auth/login
```

Driver location endpoint:

```text
POST http://localhost:5000/driver/locations
Authorization: Bearer <driver_token>
```

Admin latest driver locations endpoint:

```text
GET http://localhost:5000/admin/driver-locations
Authorization: Bearer <admin_token>
```

Admin delivery endpoints:

```text
GET http://localhost:5000/admin/deliveries
POST http://localhost:5000/admin/deliveries
Authorization: Bearer <admin_token>
```

Driver delivery endpoints:

```text
GET http://localhost:5000/driver/deliveries
PATCH http://localhost:5000/driver/deliveries/:deliveryId/status
Authorization: Bearer <driver_token>
```
