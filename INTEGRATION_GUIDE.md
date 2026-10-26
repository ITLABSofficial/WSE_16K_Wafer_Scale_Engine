# WSE_16K_Wafer_Scale_Engine: Hardware Integration & Physical Design Guide
**300mm Monolithic Wafer Packaging, Reticle Stitching, 15 kW PDN, and Liquid Cooling**

---

## 1. Top-Level Module Hierarchy & Reticle Stitching

The wafer-scale supercomputer is constructed hierarchically from reticle-limit semiconductor fields:

```
+─────────────────────────────────────────────────────────────────────────────+
|                     WAFER-SCALE HIERARCHICAL STRUCTURING                    |
|                                                                             |
|  Single Compute Core (Ara VPU + True-FMA + Systolic Unit)                   |
|  └── 4 Cores = 1 Compute Cluster (Tile) + 512 KB TCDM + Router              |
|      └── 48 Clusters (192 Cores) = 1 Reticle-Limit Die Macro (26mm x 33mm)   |
|          └── 84 Stitched Reticles = 16,384 Cores on a 300mm Monolithic Wafer |
+─────────────────────────────────────────────────────────────────────────────+
```

### Photolithographic Reticle Stitching
- Standard optical lithography scanners have a maximum reticle exposure field of approximately $26\text{ mm} \times 33\text{ mm}$ ($858\text{ mm}^2$).
- Across the 300mm wafer, 84 full and partial reticle fields are aligned edge-to-edge.
- The 9-port Express Mesh NoC routers and GALS CDC channels traverse reticle scribe lines via high-density upper metal interconnections (M11–M13), forming a seamless monolithic silicon network with zero off-chip packaging boundaries.

---

## 2. 15 kW Wafer-Scale Power Delivery Network (PDN)

Delivering 20,000 Amperes across a 300mm silicon surface at 0.75V presents extreme $I^2R$ resistive loss challenges if powered conventionally from board edges.

```
+─────────────────────────────────────────────────────────────────────────────+
|                    WAFER-SCALE PDN DISTRIBUTION TOPOLOGY                    |
|                                                                             |
|   48V Direct Current Bus (from 15 kW Rack Power Shelf)                      |
|         │                                                                   |
|         ├────────► [ High-Efficiency GaN Multiphase Buck Stages ]           |
|         │          - 48V to 1.8V Intermediate Voltage Regulators (IVR)      |
|         │                                                                   |
|         └────────► [ On-Wafer Switched-Capacitor / GaN Power Stages ]       |
|                    - 1.8V to 0.75V VDD_CORE (Distributed across 84 Dies)    |
|                    - Total Current Capability: 20,000 Amperes               |
+─────────────────────────────────────────────────────────────────────────────+
```

### Power Specifications

| Rail Name | Nominal Voltage | Total Wafer Current | Max Voltage Droop | Ripple Tolerance |
| :--- | :--- | :--- | :--- | :--- |
| **`VDD_CORE`** | **0.75 V** | **20,000 A Peak** | **$< 25\text{ mV}$** | **$< 15\text{ mV}_{p-p}$** |
| **`VDD_NOC`** | **0.75 V** | **1,200 A Peak** | **$< 15\text{ mV}$** | **$< 10\text{ mV}_{p-p}$** |
| **`VDD_HBM`** | **1.10 V** | **1,800 A Peak** | **$< 20\text{ mV}$** | **$< 15\text{ mV}_{p-p}$** |
| **`VDD_PIM`** | **0.80 V** | **2,400 A Peak** | **$< 15\text{ mV}$** | **$< 12\text{ mV}_{p-p}$** |

### Staggered Zone Activation
- The wafer is divided into 16 macro-quadrants.
- To prevent $L \cdot \frac{di}{dt}$ inrush current surges on the 48V distribution bus, quadrants are powered up with a 16-cycle progressive delay ($8.0\text{ ns}$ stagger).

---

## 3. On-Die Sensing & Lossless Telemetry Hub

The wafer embeds hundreds of distributed sensor blocks managed by the centralized telemetry network (`ara_telemetry_hub.sv`):

### 1. Digital Thermal Sensors (DTS)
- **Circuit**: On-die 10-bit SAR ADC connected to PTAT sensing nodes adjacent to every cluster's systolic multiplier array.
- **Resolution**: $0.25^\circ\text{C}$ per LSB; sampling rate $1\text{ MSPS}$.
- **Multi-Level Threshold Escalation**:
  * **$85^\circ\text{C}$**: Early warning logged in telemetry hub.
  * **$95^\circ\text{C}$**: Host notified; secondary cooling pump speed stepped up.
  * **$110^\circ\text{C}$**: Thermal runaway flag asserted; core clock throttled by $50\%$.
  * **$125^\circ\text{C}$**: Emergency hardware choke engages in $< 1\text{ cycle}$ to protect wafer silicon.

### 2. Fast Dynamic Voltage Sensors (DVS)
- High-speed ring oscillator monitors track instantaneous supply voltage every 2 clock cycles.
- Detects fast $-10\%$ sags ($630\text{ mV}$) and triggers IVR phase boosting.
- Detects severe $-20\%$ brownouts ($560\text{ mV}$) and immediately initiates clock stretching.

### 3. Central Telemetry Hub (`ara_telemetry_hub.sv`)
- **Lossless FIFO**: 64-depth packet FIFO with sticky overflow monitoring.
- **CRC-8 Frame Integrity**: Every telemetry packet includes CRC-8 polynomial protection ($x^8 + x^2 + x + 1$) to eliminate corrupt telemetry reads.
- **MMIO Telemetry Registers**: Peak temperature, lowest recorded voltage droop, and thermal trip counters are permanently recorded and readable by host software.

---

## 4. Direct-to-Silicon Microchannel Liquid Cooling Block

Dissipating 15 kW across a 300mm disc requires industrial microchannel fluid cooling:
- **Cold-Plate Material**: Oxygen-free high-conductivity (OFHC) copper cold-plate sealed directly against the wafer backside.
- **Micro-Fin Geometry**: $250\ \mu\text{m}$ fin width, $250\ \mu\text{m}$ channel width, and $2.0\text{ mm}$ fin aspect ratio.
- **Cooling Fluid**: Deionized water with anti-corrosion and biocide additives.
- **Operating Parameters**:
  * Coolant Flow Rate: **12.0 Liters / minute**.
  * Coolant Inlet Temperature: **$20^\circ\text{C}$**.
  * Coolant Outlet Temperature: **$38^\circ\text{C}$**.
  * Maximum Wafer Silicon Junction Temperature ($T_j$): **$\le 64.8^\circ\text{C}$** at full 15 kW dissipation.
