"""
CloudLab profile: 4 nodes (coord-0, slave-0, slave-1, slave-2)
connected together on a single LAN, all pinned to c220g5 hardware
at the Wisconsin CloudLab cluster, using the specified disk image.
"""

import geni.portal as portal
import geni.rspec.pg as pg

DISK_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU22-64-STD"
HARDWARE_TYPE = "c220g5"
CLUSTER_URN = "urn:publicid:IDN+wisc.cloudlab.us+authority+cm"  # CloudLab Wisconsin

# Create a portal context (no parameters needed for this profile).
pc = portal.Context()

# Build the request RSpec directly, without binding parameters.
rspec = pc.makeRequestRSpec()

lan = rspec.LAN("lan")
if_counter = 0


def add_node(name):
    global if_counter
    node = rspec.RawPC(name)
    node.disk_image = DISK_IMAGE
    node.hardware_type = HARDWARE_TYPE
    node.component_manager_id = CLUSTER_URN
    lan.addInterface(node.addInterface("if" + str(if_counter)))
    if_counter += 1
    return node


# Coordinator node
add_node("coord-0")

# Slave nodes
for i in range(3):
    add_node("slave-" + str(i))

# Output the RSpec
pc.printRequestRSpec(rspec)
