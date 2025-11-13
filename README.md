# Avenue-Segment-Assessment-Database
# Project summary
This project stores and manages road segment assessment data for urban maintenance planning. Field inspections, sensor readings, and defect reports are recorded in a relational database. The schema supports road segments, inspections, detected defects (potholes, cracks, rutting), inspectors, maintenance actions, and computed Road Condition Index (RCI). Queries and functions enable prioritization of maintenance and generation of reports.

# Objectives
Store structured data for road segments and inspections.
Record defect types and severity.
Compute a simple Road Condition Index (RCI) per inspection.
Provide queries to list worst segments, schedule maintenance, and show inspection history.

# SYSTEM REQUIREMENTS
Hardware Requirements
Smartphone or laptop for data entry
GPS-enabled device (optional)
Camera (for defect photos)
Software Requirements
Database: MySQL / PostgreSQL / SQLite
Languages: SQL, Python (optional for GUI)
Tools: Excel, QGIS (optional), Browser interface
OS: Windows / Linux

# SYSTEM ARCHITECTURE
           DATA COLLECTION
              (Manual / Survey)
                     ↓
               DATABASE (SQL)
      Segments | Defects | Inspections | RCI
                     ↓
                PROCESSING
            RCI Calculation Engine
                     ↓
             RESULT CLASSIFICATION
     Excellent | Good | Fair | Poor | Critical
# USE CASES
Identify worst road segments
Track road condition history
Prioritize maintenance
Generate city-wide condition statistics

# ADVANTAGES
Easy inspection management
Accurate defect storage
Reduces manual report writing
Supports smart city mapping
Helps allocate budgets efficiently
                     ↓
               REPORT DASHBOARD
