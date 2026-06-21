import { useEffect, useRef, useState } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import {
  APIProvider,
  Map,
  Marker,
  useMap,
  useMapsLibrary,
} from '@vis.gl/react-google-maps'

const defaultCenter = [-1.286389, 36.817223]
const googleMapsApiKey = import.meta.env.VITE_GOOGLE_MAPS_API_KEY

// Top-level switch: use Google Maps when a key is configured, otherwise fall
// back to the free Leaflet/OpenStreetMap map so the dashboard always renders.
function DriverMap({ drivers }) {
  if (googleMapsApiKey) {
    return <GoogleDriverMap drivers={drivers} apiKey={googleMapsApiKey} />
  }

  return <LeafletDriverMap drivers={drivers} />
}

/* ----------------------------- Google Maps ----------------------------- */

function GoogleDriverMap({ drivers, apiKey }) {
  const driversWithLocations = drivers.filter((driver) => driver.location)

  const points = []
  driversWithLocations.forEach((driver) => {
    points.push({ lat: driver.location.latitude, lng: driver.location.longitude })

    const activeDelivery = driver.activeDelivery
    if (
      activeDelivery?.pickupLatitude &&
      activeDelivery?.dropoffLatitude
    ) {
      points.push({
        lat: activeDelivery.pickupLatitude,
        lng: activeDelivery.pickupLongitude,
      })
      points.push({
        lat: activeDelivery.dropoffLatitude,
        lng: activeDelivery.dropoffLongitude,
      })
    }
  })

  return (
    <div className="map-container">
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={{ lat: defaultCenter[0], lng: defaultCenter[1] }}
          defaultZoom={12}
          gestureHandling="greedy"
          disableDefaultUI={false}
          clickableIcons={false}
          style={{ width: '100%', height: '100%' }}
        >
          {driversWithLocations.map((driver) => (
            <Marker
              key={`driver-${driver.driverId}`}
              position={{
                lat: driver.location.latitude,
                lng: driver.location.longitude,
              }}
              title={`${driver.driverName} · ${driver.plateNumber || 'No vehicle'}`}
            />
          ))}

          {driversWithLocations.map((driver) => {
            const activeDelivery = driver.activeDelivery
            if (
              !activeDelivery?.pickupLatitude ||
              !activeDelivery?.dropoffLatitude
            ) {
              return null
            }

            return (
              <RouteOverlay
                key={`route-${driver.driverId}`}
                from={{
                  lat: activeDelivery.pickupLatitude,
                  lng: activeDelivery.pickupLongitude,
                }}
                to={{
                  lat: activeDelivery.dropoffLatitude,
                  lng: activeDelivery.dropoffLongitude,
                }}
              />
            )
          })}

          <FitBounds points={points} />
        </Map>
      </APIProvider>
    </div>
  )
}

// Draws a road-following route (pickup -> dropoff) using Google Directions.
function RouteOverlay({ from, to }) {
  const map = useMap()
  const routesLibrary = useMapsLibrary('routes')
  const [renderer, setRenderer] = useState(null)

  useEffect(() => {
    if (!routesLibrary || !map) return undefined

    const directionsRenderer = new routesLibrary.DirectionsRenderer({
      map,
      suppressMarkers: false,
      preserveViewport: true,
      polylineOptions: { strokeColor: '#061014', strokeWeight: 5, strokeOpacity: 0.9 },
    })
    setRenderer(directionsRenderer)

    return () => directionsRenderer.setMap(null)
  }, [routesLibrary, map])

  useEffect(() => {
    if (!routesLibrary || !renderer) return

    const service = new routesLibrary.DirectionsService()
    service.route(
      { origin: from, destination: to, travelMode: 'DRIVING' },
      (result, status) => {
        if (status === 'OK' && result) renderer.setDirections(result)
      },
    )
  }, [routesLibrary, renderer, from.lat, from.lng, to.lat, to.lng])

  return null
}

// Fits the camera to all plotted points whenever they change.
function FitBounds({ points }) {
  const map = useMap()

  useEffect(() => {
    if (!map || points.length === 0) return

    if (points.length === 1) {
      map.setCenter(points[0])
      map.setZoom(14)
      return
    }

    const bounds = new window.google.maps.LatLngBounds()
    points.forEach((point) => bounds.extend(point))
    map.fitBounds(bounds, 64)
  }, [map, points])

  return null
}

/* --------------------- Leaflet / OpenStreetMap fallback --------------------- */

function LeafletDriverMap({ drivers }) {
  const mapContainerRef = useRef(null)
  const mapRef = useRef(null)
  const markerLayerRef = useRef(null)

  useEffect(() => {
    if (!mapContainerRef.current || mapRef.current) return

    mapRef.current = L.map(mapContainerRef.current).setView(defaultCenter, 12)
    markerLayerRef.current = L.layerGroup().addTo(mapRef.current)

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; OpenStreetMap contributors',
      maxZoom: 19,
    }).addTo(mapRef.current)

    return () => {
      mapRef.current?.remove()
      mapRef.current = null
      markerLayerRef.current = null
    }
  }, [])

  useEffect(() => {
    if (!mapRef.current || !markerLayerRef.current) return

    markerLayerRef.current.clearLayers()

    const driversWithLocations = drivers.filter((driver) => driver.location)
    const mapPoints = []

    driversWithLocations.forEach((driver) => {
      const { latitude, longitude, recordedAt } = driver.location
      mapPoints.push([latitude, longitude])

      L.marker([latitude, longitude])
        .bindPopup(
          `<strong>${driver.driverName}</strong><br />${driver.plateNumber || 'No vehicle'}<br />${new Date(
            recordedAt,
          ).toLocaleString()}`,
        )
        .addTo(markerLayerRef.current)

      const activeDelivery = driver.activeDelivery

      if (
        activeDelivery?.pickupLatitude &&
        activeDelivery?.pickupLongitude &&
        activeDelivery?.dropoffLatitude &&
        activeDelivery?.dropoffLongitude
      ) {
        const pickupPoint = [activeDelivery.pickupLatitude, activeDelivery.pickupLongitude]
        const dropoffPoint = [activeDelivery.dropoffLatitude, activeDelivery.dropoffLongitude]

        mapPoints.push(pickupPoint, dropoffPoint)

        L.circleMarker(pickupPoint, {
          radius: 8,
          color: '#111827',
          fillColor: '#22c55e',
          fillOpacity: 1,
          weight: 3,
        })
          .bindPopup(`<strong>Pickup</strong><br />${activeDelivery.customerName}`)
          .addTo(markerLayerRef.current)

        L.circleMarker(dropoffPoint, {
          radius: 8,
          color: '#111827',
          fillColor: '#ef4444',
          fillOpacity: 1,
          weight: 3,
        })
          .bindPopup(`<strong>Dropoff</strong><br />${activeDelivery.customerName}`)
          .addTo(markerLayerRef.current)

        L.polyline([[latitude, longitude], pickupPoint, dropoffPoint], {
          color: '#111827',
          dashArray: '8 8',
          weight: 4,
        }).addTo(markerLayerRef.current)
      }
    })

    if (mapPoints.length === 1) {
      const { latitude, longitude } = driversWithLocations[0].location
      mapRef.current.setView([latitude, longitude], 14)
    }

    if (mapPoints.length > 1) {
      const bounds = L.latLngBounds(mapPoints)
      mapRef.current.fitBounds(bounds, { padding: [40, 40] })
    }
  }, [drivers])

  return <div className="map-container" ref={mapContainerRef} />
}

export default DriverMap
