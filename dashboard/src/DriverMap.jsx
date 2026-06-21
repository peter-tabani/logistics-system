import { useEffect, useRef } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'

const defaultCenter = [-1.286389, 36.817223]

function DriverMap({ drivers }) {
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
