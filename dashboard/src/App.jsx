import { useCallback, useEffect, useRef, useState } from 'react'
import './App.css'
import DriverMap from './DriverMap.jsx'

const API_BASE_URL = 'http://localhost:5000'

function formatStatus(status) {
  return status.replaceAll('_', ' ')
}

function canUseBrowserNotifications() {
  return 'Notification' in window
}

function App() {
  const [phone, setPhone] = useState('0700000000')
  const [password, setPassword] = useState('admin123')
  const [token, setToken] = useState('')
  const [drivers, setDrivers] = useState([])
  const [deliveries, setDeliveries] = useState([])
  const [alerts, setAlerts] = useState([])
  const [trackingEvents, setTrackingEvents] = useState([])
  const [trackingSummary, setTrackingSummary] = useState(null)
  const [selectedDriverId, setSelectedDriverId] = useState('')
  const [customerName, setCustomerName] = useState('Demo Customer')
  const [pickupAddress, setPickupAddress] = useState('Nairobi Warehouse')
  const [dropoffAddress, setDropoffAddress] = useState('Westlands Office')
  const [pickupLatitude, setPickupLatitude] = useState('-1.286389')
  const [pickupLongitude, setPickupLongitude] = useState('36.817223')
  const [dropoffLatitude, setDropoffLatitude] = useState('-1.264100')
  const [dropoffLongitude, setDropoffLongitude] = useState('36.802800')
  const [message, setMessage] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [autoRefresh, setAutoRefresh] = useState(true)
  const [notificationsEnabled, setNotificationsEnabled] = useState(
    canUseBrowserNotifications() && Notification.permission === 'granted',
  )
  const notifiedAlertIdsRef = useRef(new Set())

  function notifyNewAlerts(nextAlerts) {
    if (!canUseBrowserNotifications() || Notification.permission !== 'granted') return

    nextAlerts.forEach((alert) => {
      if (notifiedAlertIdsRef.current.has(alert.id)) return

      notifiedAlertIdsRef.current.add(alert.id)
      new Notification(alert.title, { body: alert.message })
    })
  }

  async function enableNotifications() {
    if (!canUseBrowserNotifications()) {
      setMessage('This browser does not support notifications.')
      return
    }

    const permission = await Notification.requestPermission()
    setNotificationsEnabled(permission === 'granted')
    setMessage(
      permission === 'granted'
        ? 'Browser notifications enabled.'
        : 'Notifications were not enabled.',
    )
  }

  const loadDashboardData = useCallback(async (authToken = token, options = {}) => {
    if (!authToken) return

    if (!options.silent) {
      setIsLoading(true)
      setMessage('')
    }

    try {
      const [driversResponse, deliveriesResponse, alertsResponse, eventsResponse] = await Promise.all([
        fetch(`${API_BASE_URL}/admin/driver-locations`, {
          headers: { Authorization: `Bearer ${authToken}` },
        }),
        fetch(`${API_BASE_URL}/admin/deliveries`, {
          headers: { Authorization: `Bearer ${authToken}` },
        }),
        fetch(`${API_BASE_URL}/admin/tracking-alerts`, {
          headers: { Authorization: `Bearer ${authToken}` },
        }),
        fetch(`${API_BASE_URL}/admin/tracking-events?limit=20`, {
          headers: { Authorization: `Bearer ${authToken}` },
        }),
      ])

      const driversData = await driversResponse.json()
      const deliveriesData = await deliveriesResponse.json()
      const alertsData = await alertsResponse.json()
      const eventsData = await eventsResponse.json()

      if (!driversResponse.ok) {
        throw new Error(driversData.message || 'Could not load drivers.')
      }

      if (!deliveriesResponse.ok) {
        throw new Error(deliveriesData.message || 'Could not load deliveries.')
      }

      if (!alertsResponse.ok) {
        throw new Error(alertsData.message || 'Could not load tracking alerts.')
      }

      if (!eventsResponse.ok) {
        throw new Error(eventsData.message || 'Could not load tracking timeline.')
      }

      setDrivers(driversData.drivers)
      setDeliveries(deliveriesData.deliveries)
      setAlerts(alertsData.alerts)
      setTrackingEvents(eventsData.events)
      setTrackingSummary(alertsData.summary)
      notifyNewAlerts(alertsData.alerts)

      if (!selectedDriverId && driversData.drivers[0]) {
        setSelectedDriverId(String(driversData.drivers[0].driverId))
      }

      if (!options.silent) {
        setMessage('Monitoring data refreshed.')
      }
    } catch (error) {
      setMessage(error.message)
    } finally {
      if (!options.silent) {
        setIsLoading(false)
      }
    }
  }, [selectedDriverId, token])

  useEffect(() => {
    if (!token || !autoRefresh) return undefined

    const timer = window.setInterval(() => {
      loadDashboardData(token, { silent: true })
    }, 10000)

    return () => window.clearInterval(timer)
  }, [autoRefresh, loadDashboardData, token])

  async function login(event) {
    event.preventDefault()
    setIsLoading(true)
    setMessage('')

    try {
      const response = await fetch(`${API_BASE_URL}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ phone, password }),
      })
      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || 'Login failed.')
      }

      if (data.user.role !== 'admin') {
        throw new Error('Only admin users can open this dashboard.')
      }

      setToken(data.token)
      await loadDashboardData(data.token)
      setMessage(`Logged in as ${data.user.fullName}`)
    } catch (error) {
      setMessage(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  async function createDelivery(event) {
    event.preventDefault()

    if (!selectedDriverId) {
      setMessage('Select a driver first.')
      return
    }

    setIsLoading(true)
    setMessage('')

    try {
      const response = await fetch(`${API_BASE_URL}/admin/deliveries`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          driverId: Number(selectedDriverId),
          customerName,
          pickupAddress,
          pickupLatitude: Number(pickupLatitude),
          pickupLongitude: Number(pickupLongitude),
          dropoffAddress,
          dropoffLatitude: Number(dropoffLatitude),
          dropoffLongitude: Number(dropoffLongitude),
        }),
      })
      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || 'Could not create delivery.')
      }

      setMessage('Delivery assigned. Driver tracking will appear automatically.')
      setCustomerName('')
      setPickupAddress('')
      setDropoffAddress('')
      await loadDashboardData(token)
    } catch (error) {
      setMessage(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  if (!token) {
    return (
      <main className="login-screen">
        <section className="login-card">
          <div>
            <div className="login-brand">
              <img alt="Stan" src="/stan-logo.svg" />
              <span>Stan</span>
            </div>
            <p className="eyebrow">Logistics Command</p>
            <h1>Shipping made simple</h1>
            <p>Sign in to monitor drivers, alerts, and delivery movement.</p>
          </div>
          <form onSubmit={login}>
            <label>
              Phone
              <input value={phone} onChange={(event) => setPhone(event.target.value)} />
            </label>
            <label>
              Password
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
              />
            </label>
            <button disabled={isLoading} type="submit">
              {isLoading ? 'Signing in...' : 'Open Dashboard'}
            </button>
            <span className="hint">Test admin: 0700000000 / admin123</span>
          </form>
          {message ? <p className="message compact">{message}</p> : null}
        </section>
      </main>
    )
  }

  const activeDeliveries = deliveries.filter((delivery) => delivery.status !== 'delivered')
  const completedDeliveries = deliveries.filter((delivery) => delivery.status === 'delivered')
  const liveDrivers = trackingSummary?.driversWithRecentLocation ?? 0
  const activeDrivers = trackingSummary?.activeDrivers ?? 0
  const completionRate = deliveries.length
    ? Math.round((completedDeliveries.length / deliveries.length) * 100)
    : 0
  const alertTone = alerts.length ? 'critical' : 'healthy'

  return (
    <main className="monitor-shell">
      <header className="command-bar">
        <div>
          <span className="brand-mark"><img alt="Stan" src="/stan-logo.svg" /></span>
          <div>
            <strong>Stan Command</strong>
            <span>Owner monitoring console</span>
          </div>
        </div>
        <div className="command-actions">
          <span className={`system-pill ${alertTone}`}>
            {alerts.length ? `${alerts.length} alerts` : 'All systems clear'}
          </span>
          {canUseBrowserNotifications() && !notificationsEnabled ? (
            <button type="button" onClick={enableNotifications}>
              Enable Alerts
            </button>
          ) : null}
          <label className="auto-refresh-toggle">
            <input
              checked={autoRefresh}
              type="checkbox"
              onChange={(event) => setAutoRefresh(event.target.checked)}
            />
            Live
          </label>
          <button disabled={isLoading} type="button" onClick={() => loadDashboardData()}>
            {isLoading ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
      </header>

      <section className="ops-hero">
        <div className="ops-copy">
          <p className="eyebrow">Stan Logistics OS</p>
          <h1>Move every driver, parcel, and alert from one premium command center.</h1>
          <p>
            Live GPS visibility, dispatch assignment, tracking events, and exception monitoring for the Nairobi fleet.
          </p>
          <div className="fleet-badges">
            <span>Bike</span>
            <span>Truck</span>
            <span>Car</span>
          </div>
        </div>
        <div className="hero-metrics">
          <article>
            <span>Active drivers</span>
            <strong>{activeDrivers}</strong>
            <small>{liveDrivers} sending live GPS</small>
          </article>
          <article>
            <span>Open deliveries</span>
            <strong>{activeDeliveries.length}</strong>
            <small>{completedDeliveries.length} completed</small>
          </article>
          <article className={alerts.length ? 'danger' : 'clear'}>
            <span>Tracking alerts</span>
            <strong>{alerts.length}</strong>
            <small>{completionRate}% completion rate</small>
          </article>
        </div>
      </section>

      <section className="map-command">
        <div className="map-stage">
          <div className="map-toolbar">
            <div>
              <strong>Live Nairobi Map</strong>
              <span>Driver route, pickup, and dropoff visibility</span>
            </div>
            <span>{autoRefresh ? 'Auto-refresh on' : 'Manual refresh'}</span>
          </div>
          <DriverMap drivers={drivers} />
        </div>

        <aside className="live-panel">
          <div className="panel-heading">
            <span className={alerts.length ? 'pulse danger' : 'pulse ok'} />
            <div>
              <h1>{alerts.length ? 'Attention Needed' : 'Live Tracking'}</h1>
              <p>{alerts.length ? 'Resolve current tracking alerts.' : 'All active drivers are monitored.'}</p>
            </div>
          </div>

          <div className="metric-row">
            <div>
              <strong>{trackingSummary?.activeDrivers ?? 0}</strong>
              <span>Active</span>
            </div>
            <div>
              <strong>{trackingSummary?.driversWithRecentLocation ?? 0}</strong>
              <span>Live</span>
            </div>
            <div className={alerts.length ? 'metric-alert' : ''}>
              <strong>{alerts.length}</strong>
              <span>Alerts</span>
            </div>
          </div>

          <div className="alert-stack">
            {alerts.length ? (
              alerts.map((alert) => (
                <article className={`alert-item ${alert.severity}`} key={alert.id}>
                  <strong>{alert.title}</strong>
                  <span>{alert.message}</span>
                </article>
              ))
            ) : (
              <article className="alert-item clear">
                <strong>No suspicious activity</strong>
                <span>The dashboard will notify you if tracking stops or a driver is stationary too long.</span>
              </article>
            )}
          </div>

          <div className="timeline-panel">
            <div className="section-title">
              <strong>Tracking Timeline</strong>
              <span>GPS, app, and network events</span>
            </div>
            {trackingEvents.length ? (
              <div className="timeline-list">
                {trackingEvents.slice(0, 8).map((event) => (
                  <article className={`timeline-item ${event.severity}`} key={event.id}>
                    <span className="timeline-dot" />
                    <div>
                      <strong>{event.driverName}</strong>
                      <span>{event.message}</span>
                      <small>{new Date(event.recordedAt).toLocaleString()}</small>
                    </div>
                  </article>
                ))}
              </div>
            ) : (
              <article className="alert-item clear">
                <strong>No tracking events yet</strong>
                <span>GPS-off, app background, and tracking-resume events will appear here.</span>
              </article>
            )}
          </div>

          <div className="driver-strip">
            {drivers.map((driver) => (
              <article className="driver-row" key={driver.driverId}>
                <div>
                  <strong>{driver.driverName}</strong>
                  <span>{driver.plateNumber || 'No vehicle'} · {driver.activeDelivery?.status || 'no active trip'}</span>
                </div>
                <small>
                  {driver.location
                    ? new Date(driver.location.recordedAt).toLocaleTimeString()
                    : 'No GPS'}
                </small>
              </article>
            ))}
          </div>
        </aside>
      </section>

      <section className="dispatch-drawer">
        <form className="dispatch-form" onSubmit={createDelivery}>
          <div className="form-heading">
            <p className="eyebrow">Dispatch</p>
            <h2>Assign Delivery</h2>
            <p>Once assigned, driver tracking starts automatically when the driver app is open.</p>
          </div>
          <label>
            Driver
            <select
              value={selectedDriverId}
              onChange={(event) => setSelectedDriverId(event.target.value)}
            >
              {drivers.map((driver) => (
                <option key={driver.driverId} value={driver.driverId}>
                  {driver.driverName} - {driver.plateNumber || 'No vehicle'}
                </option>
              ))}
            </select>
          </label>
          <label>
            Customer
            <input
              value={customerName}
              onChange={(event) => setCustomerName(event.target.value)}
              placeholder="Customer name"
            />
          </label>
          <label>
            Pickup
            <input
              value={pickupAddress}
              onChange={(event) => setPickupAddress(event.target.value)}
              placeholder="Pickup address"
            />
          </label>
          <div className="coordinate-row">
            <label>
              Pickup Lat
              <input
                value={pickupLatitude}
                onChange={(event) => setPickupLatitude(event.target.value)}
                placeholder="-1.286389"
              />
            </label>
            <label>
              Pickup Lng
              <input
                value={pickupLongitude}
                onChange={(event) => setPickupLongitude(event.target.value)}
                placeholder="36.817223"
              />
            </label>
          </div>
          <label>
            Dropoff
            <input
              value={dropoffAddress}
              onChange={(event) => setDropoffAddress(event.target.value)}
              placeholder="Dropoff address"
            />
          </label>
          <div className="coordinate-row">
            <label>
              Dropoff Lat
              <input
                value={dropoffLatitude}
                onChange={(event) => setDropoffLatitude(event.target.value)}
                placeholder="-1.264100"
              />
            </label>
            <label>
              Dropoff Lng
              <input
                value={dropoffLongitude}
                onChange={(event) => setDropoffLongitude(event.target.value)}
                placeholder="36.802800"
              />
            </label>
          </div>
          <button disabled={isLoading || drivers.length === 0} type="submit">
            {isLoading ? 'Assigning...' : 'Assign'}
          </button>
        </form>

        <div className="trip-board">
          <div className="section-title trip-title">
            <div>
              <strong>Recent Deliveries</strong>
              <span>Latest assignments and route readiness</span>
            </div>
            <span>{deliveries.length} total</span>
          </div>
          <div className="trip-list">
            {deliveries.length ? (
              deliveries.slice(0, 6).map((delivery) => (
                <article className="trip-row" key={delivery.id}>
                  <div>
                    <strong>{delivery.customerName}</strong>
                    <span>
                      {delivery.pickupAddress} → {delivery.dropoffAddress}
                      {delivery.pickupLatitude && delivery.dropoffLatitude ? ' · route ready' : ' · coordinates needed'}
                    </span>
                  </div>
                  <span className={`status-pill ${delivery.status}`}>{formatStatus(delivery.status)}</span>
                </article>
              ))
            ) : (
              <article className="trip-row empty">
                <div>
                  <strong>No deliveries yet</strong>
                  <span>Create the first dispatch assignment to populate this board.</span>
                </div>
              </article>
            )}
          </div>
        </div>
      </section>

      {message ? <p className="toast-message">{message}</p> : null}
    </main>
  )
}

export default App
