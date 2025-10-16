package ch.ethz.systems.netbench.xpt.aifo.ports.BRFQ;

import ch.ethz.systems.netbench.core.network.Packet;
import ch.ethz.systems.netbench.xpt.tcpbase.FullExtTcpPacket;
import ch.ethz.systems.netbench.xpt.tcpbase.PriorityHeader;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.PriorityBlockingQueue;
import java.util.concurrent.locks.ReentrantLock;
import java.util.concurrent.locks.Lock;


public class BRFQQueue extends PriorityBlockingQueue implements Queue {

    private final int maxItems;
    private Lock reentrantLock;
    private int ownId;
    private int targetId;

    private final Map flowBids;
    private int round;

    public BRFQQueue(long maxItems, int targetId, int ownId){
        this.ownId = ownId;
        this.targetId = targetId;

        this.maxItems = (int)maxItems;
        this.reentrantLock = new ReentrantLock();

        this.flowBids = new HashMap();
        this.round = 0;
    }


    public int computeRank(Packet p){
        int bid = this.round;
        if(flowBids.containsKey(p.getFlowId())){
            if(bid < (int)flowBids.get(p.getFlowId())){
                bid = (int)flowBids.get(p.getFlowId());
            }
        }

        bid = bid + (int) (p.getSizeBit());
        flowBids.put(p.getFlowId(), bid);
        return bid;
    }

    /*Round is the virtual start time of the last dequeued packet across all flows*/
    public void updateRound(Packet p){
        PriorityHeader header = (PriorityHeader) p;
        int rank = (int)header.getPriority();
        this.round = rank;
    }

    public Packet offerPacket(Object o, int ownID) {

        this.reentrantLock.lock();

        /*Rank computation*/
        FullExtTcpPacket packet = (FullExtTcpPacket) o;
        int rank = this.computeRank(packet);

        PriorityHeader header = (PriorityHeader) packet;
        header.setPriority((long)rank); // This makes no effect since each switch recomputes the ranks

        boolean success = true;
        try {
            /* As the original PBQ is has no limited size, the packet is always inserted */
            success = super.offer(packet); /* This method will always return true */

            /* We control the size by removing the extra packet */
            if (this.size()>maxItems-1){
                Object[] contentPIFO = this.toArray();
                Arrays.sort(contentPIFO);
                packet = (FullExtTcpPacket) contentPIFO[this.size()-1];
                if (flowBids.get(packet.getFlowId()) != null){
                    flowBids.put(packet.getFlowId(), (int)flowBids.get(packet.getFlowId()) - (int)packet.getSizeBit());
                }
                this.remove(packet);
                return packet;
            }
            return null;
        } finally {
            this.reentrantLock.unlock();
        }
    }

    @Override
    public Object poll() {
        this.reentrantLock.lock();
        try {
            Packet packet = (Packet) super.poll(); // As the super queue is unbounded, this method will always return true

            // Update round number
            this.updateRound(packet);
            return packet;
        } catch (Exception e){
            return null;
        } finally {
            this.reentrantLock.unlock();
        }
    }

    @Override
    public int size() {
        return super.size();
    }

    @Override
    public boolean isEmpty() {
        return super.isEmpty();
    }

}
