package ch.ethz.systems.netbench.xpt.aifo.ports.BRFQ;

import ch.ethz.systems.netbench.core.log.SimulationLogger;
import ch.ethz.systems.netbench.core.network.Link;
import ch.ethz.systems.netbench.core.network.NetworkDevice;
import ch.ethz.systems.netbench.core.network.OutputPort;
import ch.ethz.systems.netbench.core.run.infrastructure.OutputPortGenerator;

public class BRFQOutputPortGenerator extends OutputPortGenerator {

    private final long sizePackets;

    public BRFQOutputPortGenerator(long sizePackets) {
        this.sizePackets = sizePackets;
        SimulationLogger.logInfo("Port", "BRFQ(sizePackets=" + sizePackets + ")");
    }

    @Override
    public OutputPort generate(NetworkDevice ownNetworkDevice, NetworkDevice towardsNetworkDevice, Link link) {
        return new BRFQOutputPort(ownNetworkDevice, towardsNetworkDevice, link, sizePackets);
    }

}