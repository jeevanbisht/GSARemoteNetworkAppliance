# RNFleetManager – Sample Configurations

## Entra / GSA BGP Connectivity Configuration

> Source: Microsoft Graph API — `GET /beta/networkAccess/connectivity/remoteNetworks/{id}/connectivityConfiguration`

```json
{
  "@odata.context": "https://graph.microsoft.com/beta/$metadata#networkAccess/connectivity/remoteNetworks('0509862d-5820-4b00-aeaf-5b35fe5e2528')/connectivityConfiguration/$entity",
  "remoteNetworkId": "0509862d-5820-4b00-aeaf-5b35fe5e2528",
  "remoteNetworkName": "Test2",
  "links": [
    {
      "id": "7217b9f3-511a-4789-8054-a23933713b7f",
      "displayName": "TestLink1",
      "localConfigurations": [
        {
          "endpoint": "20.98.121.145",
          "asn": 65476,
          "bgpAddress": "192.168.10.1",
          "region": "westUS2"
        }
      ],
      "peerConfiguration": {
        "endpoint": "20.168.67.71",
        "asn": 65001,
        "bgpAddress": "192.168.10.2"
      }
    }
  ]
}
```

### Key Values (TestLink1)

| Field | Entra Side (Local / GSA Gateway) | Appliance Side (Peer) |
|-------|-----------------------------------|-----------------------|
| Public Endpoint | `20.98.121.145` | `20.168.67.71` |
| ASN | `65476` | `65001` |
| BGP Peering Address | `192.168.10.1` | `192.168.10.2` |
| Region | `westUS2` | — |

---

## Architecture Diagram

```
                        IPSec Tunnel
  ┌─────────────────┐ ◄──────────────► ┌──────────────────┐
  │    Linux VM     │                   │  GSA VPN Gateway │
  │                 │                   │                  │
  │ Public IP:      │                   │ Public IP:       │
  │ <your-vm-ip>    │                   │ <gsa-vpn-ip>     │
  │                 │                   │                  │
  │  ipsec0 IF      │   BGP Session     │   BGP Peer       │
  │  192.168.1.2 ◄──┼ - - - - - - - - ►│   192.168.1.1    │
  │  AS 65001       │   (Established)   │   AS 65476       │
  │                 │                   │                  │
  │ • strongSwan    │                   │ • Route Advert.  │
  │ • FRRouting     │                   │ • Remote Nets:   │
  │ • Local Nets:   │                   │   192.168.0.0/16 │
  │   10.0.0.0/24   │                   │   0.0.0.0/0      │
  │   172.16.0.0/24 │                   │                  │
  └─────────────────┘                   └──────────────────┘
```

### Diagram Notes

| Component | Appliance (Linux VM) | GSA Gateway (Entra) |
|-----------|----------------------|---------------------|
| Stack | strongSwan (IPSec) + FRRouting (BGP) | Microsoft GSA VPN Gateway |
| IPSec tunnel IF | `ipsec0` @ `192.168.1.2` | `192.168.1.1` |
| BGP ASN | `65001` | `65476` |
| Advertised routes | `10.0.0.0/24`, `172.16.0.0/24` | `192.168.0.0/16`, `0.0.0.0/0` |
| Tunnel direction | Outbound initiator | Responder |
