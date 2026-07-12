import { useCallback, useEffect, useRef, useState } from 'react'
import './App.css'
import DriverMap from './DriverMap.jsx'

// Defaults to the always-on cloud backend; override with VITE_API_BASE_URL for
// local development (e.g. http://localhost:5000).
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'https://stan-backend.onrender.com'

function formatStatus(status) {
  return status.replaceAll('_', ' ')
}

function formatKsh(amount) {
  return `Ksh ${Math.round(Number(amount) || 0).toLocaleString('en-KE')}`
}

function paymentLabel(delivery) {
  if (delivery.paymentStatus === 'paid') {
    return `Paid · ${(delivery.paymentMethod || '').toUpperCase()}`
  }
  if (delivery.paymentStatus === 'failed') return 'Failed'
  return 'Unpaid'
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
  const [fareAmount, setFareAmount] = useState('300')
  const [receiverName, setReceiverName] = useState('')
  const [receiverPhone, setReceiverPhone] = useState('')
  const [collectionPoints, setCollectionPoints] = useState([])
  const [selectedCollectionPointId, setSelectedCollectionPointId] = useState('')
  const [cpName, setCpName] = useState('')
  const [cpAddress, setCpAddress] = useState('')
  const [cpLatitude, setCpLatitude] = useState('-1.283300')
  const [cpLongitude, setCpLongitude] = useState('36.816700')
  const [leg2Selections, setLeg2Selections] = useState({})
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
      const [driversResponse, deliveriesResponse, alertsResponse, eventsResponse, pointsResponse] = await Promise.all([
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
        fetch(`${API_BASE_URL}/admin/collection-points`, {
          headers: { Authorization: `Bearer ${authToken}` },
        }),
      ])

      const driversData = await driversResponse.json()
      const deliveriesData = await deliveriesResponse.json()
      const alertsData = await alertsResponse.json()
      const eventsData = await eventsResponse.json()
      const pointsData = pointsResponse.ok ? await pointsResponse.json() : { collectionPoints: [] }

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
      setCollectionPoints(pointsData.collectionPoints || [])
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
          fareAmount: Number(fareAmount) || 0,
          receiverName,
          receiverPhone,
          collectionPointId: selectedCollectionPointId ? Number(selectedCollectionPointId) : null,
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
      setReceiverName('')
      setReceiverPhone('')
      await loadDashboardData(token)
    } catch (error) {
      setMessage(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  async function createCollectionPoint(event) {
    event.preventDefault()
    setIsLoading(true)
    setMessage('')

    try {
      const response = await fetch(`${API_BASE_URL}/admin/collection-points`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          name: cpName,
          address: cpAddress,
          latitude: Number(cpLatitude),
          longitude: Number(cpLongitude),
        }),
      })
      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || 'Could not create the collection point.')
      }

      setMessage(`Collection point "${data.collectionPoint.name}" created.`)
      setCpName('')
      setCpAddress('')
      await loadDashboardData(token)
    } catch (error) {
      setMessage(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  async function toggleCollectionPoint(point) {
    try {
      const response = await fetch(`${API_BASE_URL}/admin/collection-points/${point.id}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ isActive: !point.isActive }),
      })
      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || 'Could not update the collection point.')
      }

      await loadDashboardData(token, { silent: true })
    } catch (error) {
      setMessage(error.message)
    }
  }

  async function postRiderAction(deliveryId, path, failureText) {
    const driverId = leg2Selections[deliveryId]

    if (!driverId) {
      setMessage('Choose a rider first.')
      return
    }

    setIsLoading(true)
    setMessage('')

    try {
      const response = await fetch(`${API_BASE_URL}/admin/deliveries/${deliveryId}/${path}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ driverId: Number(driverId) }),
      })
      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || failureText)
      }

      setMessage(data.message)
      await loadDashboardData(token)
    } catch (error) {
      setMessage(error.message)
    } finally {
      setIsLoading(false)
    }
  }

  const dispatchLeg2 = (deliveryId) => postRiderAction(deliveryId, 'dispatch-leg2', 'Could not dispatch leg 2.')
  const assignRider = (deliveryId) => postRiderAction(deliveryId, 'assign', 'Could not assign a rider.')

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
            <h1>Delivery made easy</h1>
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
  const paidDeliveries = deliveries.filter((delivery) => delivery.paymentStatus === 'paid')
  const paidCount = paidDeliveries.length
  const collected = paidDeliveries.reduce(
    (sum, delivery) => sum + (Number(delivery.fareAmount) || 0) + (Number(delivery.tipAmount) || 0),
    0,
  )
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
          <article>
            <span>Collected (demo)</span>
            <strong>{formatKsh(collected)}</strong>
            <small>{paidCount} paid · Cash + M-Pesa</small>
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
          <div className="coordinate-row">
            <label>
              Receiver name
              <input
                value={receiverName}
                onChange={(event) => setReceiverName(event.target.value)}
                placeholder="Who receives the parcel"
              />
            </label>
            <label>
              Receiver phone
              <input
                value={receiverPhone}
                onChange={(event) => setReceiverPhone(event.target.value)}
                placeholder="07XXXXXXXX"
              />
            </label>
          </div>
          <label>
            Fare (Ksh)
            <input
              value={fareAmount}
              onChange={(event) => setFareAmount(event.target.value)}
              placeholder="300"
            />
          </label>
          <label>
            Route via collection point (optional)
            <select
              value={selectedCollectionPointId}
              onChange={(event) => setSelectedCollectionPointId(event.target.value)}
            >
              <option value="">Direct — no collection point</option>
              {collectionPoints
                .filter((point) => point.isActive)
                .map((point) => (
                  <option key={point.id} value={point.id}>
                    {point.name} — {point.address}
                  </option>
                ))}
            </select>
          </label>
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
                    </span>
                    {delivery.receiverName ? (
                      <span>Receiver: {delivery.receiverName}{delivery.receiverPhone ? ` · ${delivery.receiverPhone}` : ''}</span>
                    ) : null}
                    {delivery.viaCollectionPoint ? (
                      <span>
                        Via {delivery.collectionPointName || 'collection point'} · leg {delivery.currentLeg} of 2
                        {delivery.leg1DriverName ? ` · L1 ${delivery.leg1DriverName}` : ''}
                        {delivery.leg2DriverName ? ` · L2 ${delivery.leg2DriverName}` : ''}
                      </span>
                    ) : null}
                    {delivery.status === 'at_collection_point' || delivery.status === 'pending' ? (
                      <div className="leg2-dispatch">
                        <select
                          value={leg2Selections[delivery.id] || ''}
                          onChange={(event) =>
                            setLeg2Selections((prev) => ({ ...prev, [delivery.id]: event.target.value }))
                          }
                        >
                          <option value="">
                            {delivery.status === 'pending' ? 'Choose rider…' : 'Choose leg 2 rider…'}
                          </option>
                          {drivers.map((driver) => (
                            <option key={driver.driverId} value={driver.driverId}>
                              {driver.driverName}
                            </option>
                          ))}
                        </select>
                        <button
                          disabled={isLoading}
                          type="button"
                          onClick={() =>
                            delivery.status === 'pending' ? assignRider(delivery.id) : dispatchLeg2(delivery.id)
                          }
                        >
                          {delivery.status === 'pending' ? 'Assign rider' : 'Dispatch leg 2'}
                        </button>
                      </div>
                    ) : null}
                    <div className="trip-meta">
                      {delivery.trackingCode ? (
                        <span className="code-chip">{delivery.trackingCode}</span>
                      ) : null}
                      <span className="fare">{formatKsh(delivery.fareAmount)}</span>
                      <span className={`pay-chip ${delivery.paymentStatus}`}>{paymentLabel(delivery)}</span>
                      {delivery.payer === 'sender' ? (
                        <span className="pin-chip">Sender pays</span>
                      ) : null}
                      {delivery.deliveryPin && delivery.status !== 'delivered' ? (
                        <span className="pin-chip">PIN {delivery.deliveryPin}</span>
                      ) : null}
                    </div>
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

      <section className="dispatch-drawer">
        <form className="dispatch-form" onSubmit={createCollectionPoint}>
          <div className="form-heading">
            <p className="eyebrow">Network</p>
            <h2>Collection Points</h2>
            <p>Parcels can route sender → collection point → receiver in two rider legs.</p>
          </div>
          <label>
            Name
            <input
              value={cpName}
              onChange={(event) => setCpName(event.target.value)}
              placeholder="e.g. Stan Hub CBD"
            />
          </label>
          <label>
            Address
            <input
              value={cpAddress}
              onChange={(event) => setCpAddress(event.target.value)}
              placeholder="Street / building"
            />
          </label>
          <div className="coordinate-row">
            <label>
              Lat
              <input
                value={cpLatitude}
                onChange={(event) => setCpLatitude(event.target.value)}
                placeholder="-1.283300"
              />
            </label>
            <label>
              Lng
              <input
                value={cpLongitude}
                onChange={(event) => setCpLongitude(event.target.value)}
                placeholder="36.816700"
              />
            </label>
          </div>
          <button disabled={isLoading} type="submit">
            {isLoading ? 'Saving...' : 'Add collection point'}
          </button>
        </form>

        <div className="trip-board">
          <div className="section-title trip-title">
            <div>
              <strong>Network Points</strong>
              <span>Active points appear in the dispatch form and customer booking</span>
            </div>
            <span>{collectionPoints.length} total</span>
          </div>
          <div className="trip-list">
            {collectionPoints.length ? (
              collectionPoints.map((point) => (
                <article className="trip-row" key={point.id}>
                  <div>
                    <strong>{point.name}</strong>
                    <span>{point.address}</span>
                    <div className="trip-meta">
                      <span className="code-chip">
                        {Number(point.latitude).toFixed(4)}, {Number(point.longitude).toFixed(4)}
                      </span>
                    </div>
                  </div>
                  <button
                    className={`toggle-pill ${point.isActive ? 'on' : 'off'}`}
                    type="button"
                    onClick={() => toggleCollectionPoint(point)}
                  >
                    {point.isActive ? 'Active' : 'Inactive'}
                  </button>
                </article>
              ))
            ) : (
              <article className="trip-row empty">
                <div>
                  <strong>No collection points yet</strong>
                  <span>Add the first hub to enable two-leg routing.</span>
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
