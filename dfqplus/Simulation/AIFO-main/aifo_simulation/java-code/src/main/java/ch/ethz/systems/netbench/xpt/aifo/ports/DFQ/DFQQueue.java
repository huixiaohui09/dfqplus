package ch.ethz.systems.netbench.xpt.aifo.ports.DFQ;

import ch.ethz.systems.netbench.core.network.Packet;
import ch.ethz.systems.netbench.xpt.tcpbase.FullExtTcpPacket;
import ch.ethz.systems.netbench.xpt.tcpbase.PriorityHeader;

import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.locks.ReentrantLock;

public class DFQQueue implements Queue<Packet> {

    private static class QueueInfo {
        ArrayBlockingQueue<FullExtTcpPacket> queue;
        int priority;
        long originalCapacity;
        QueueInfo child;
        long remainingCapacity;

        QueueInfo(long capacity, int priority) {
            this.queue = new ArrayBlockingQueue<>((int) capacity);
            this.priority = priority;
            this.originalCapacity = capacity;
            this.remainingCapacity = capacity;
        }
    }

    private final ArrayList<QueueInfo> queueList;
    private final Map<Long, Long> flowBids;
    private final TreeMap<Long, Long> rankBitSumMap;
    private final long bytesPerRound;
    private long currentRound;
    private final ReentrantLock reentrantLock;
    private final long totalCapacity;

    private final int windowSize; // Base window size
    private final double k; // Weight coefficient for queue length
    private int currentW; // Dynamic window size
    private int packetCount = 0; // Packet count within the current window
    private final Deque<Long> arrivalTimestamps = new LinkedList<>(); // Queue of arrival timestamps
    private static final int LAMBDA_WINDOW_SIZE = 10; // Time window size for computing λ

    public DFQQueue(long numQueues, long perQueueCapacity, long bytesPerRound, int windowSize, int ownId) {
        this.queueList = new ArrayList<>((int) numQueues);
        this.flowBids = new HashMap<>();
        this.rankBitSumMap = new TreeMap<>();
        this.bytesPerRound = bytesPerRound;
        this.totalCapacity = numQueues * perQueueCapacity;
        this.reentrantLock = new ReentrantLock();
        this.currentRound = 0;
        this.windowSize = windowSize;
        this.k = 0.5;
        this.currentW = windowSize; // Initial window size W0

        // Initialize queues
        for (int i = 0; i < numQueues; i++) {
            queueList.add(new QueueInfo(perQueueCapacity, i));
        }
    }

    // Compute λ (packet arrival rate, packets per second)
    private double calculateLambda() {
        if (arrivalTimestamps.size() < 2) {
            return 0.0;
        }
        long oldest = arrivalTimestamps.peekFirst();
        long newest = arrivalTimestamps.peekLast();
        double timeIntervalSec = (newest - oldest) / 1e9;
        return timeIntervalSec > 0 ? (arrivalTimestamps.size() - 1) / timeIntervalSec : 0.0;
    }

    // Dynamically compute window size
    private void updateWindowSize() {
        int currentCLength = queueList.stream().mapToInt(q -> q.queue.size()).sum();
        
        double lambda = calculateLambda();
        double term1 = 1.0 / (1 + lambda);
        double term2 = k * currentCLength / totalCapacity;
        currentW = (int) (windowSize * (term1 + term2));
        currentW = Math.max(1, currentW); 
    }

    private int getCurrentHighestPriority() {
        return queueList.isEmpty() ? -1 : queueList.get(0).priority;
    }

    @Override
    public boolean offer(Packet packet) {
        reentrantLock.lock();
        try {
            FullExtTcpPacket p = (FullExtTcpPacket) packet;
            long rankComputed = computeRound(p);
            long packetSize = packet.getSizeBit();
            ((PriorityHeader) p).setPriority(rankComputed);

            long now = System.nanoTime();
            arrivalTimestamps.add(now);
            while (arrivalTimestamps.size() > LAMBDA_WINDOW_SIZE) {
                arrivalTimestamps.removeFirst();
            }

            updateWindowSize();

            if (++packetCount >= currentW) {
                manageQueues();
                packetCount = 0;
            }

            long accumulatedBits = 0;
            long previousThresholdBits = 0;
            for (QueueInfo qInfo : queueList) {
                accumulatedBits = (long) qInfo.remainingCapacity * packetSize + previousThresholdBits;

                Long thresholdRank = findRankThreshold(accumulatedBits);

                if (rankComputed <= thresholdRank) {
                    if (offerToQueue(qInfo, p)) {
                        return true;
                    }
                }
                previousThresholdBits = findBitsForRank(thresholdRank);
            }
            return false;
        } finally {
            reentrantLock.unlock();
        }
    }
    
    private long computeRound(Packet p) {
        long flowId = p.getFlowId();
        long currentBid = currentRound * bytesPerRound;
        long bid = Math.max(currentBid, flowBids.getOrDefault(flowId, currentBid));
        bid += p.getSizeBit() / 8;
        long packetRound = bid / bytesPerRound;
        flowBids.put(flowId, bid);

        rankBitSumMap.merge(packetRound, p.getSizeBit(), Long::sum);
        return packetRound;
    }

    private boolean offerToQueue(QueueInfo qInfo, FullExtTcpPacket p) {
        if (qInfo.queue.offer(p)) {
            qInfo.remainingCapacity--;
            return true;
        }
        return false;
    }

    private Long findRankThreshold(long targetBits) {
        Map.Entry<Long, Long> entry = rankBitSumMap.ceilingEntry(targetBits);
        return entry != null ? entry.getKey() : (rankBitSumMap.isEmpty() ? Long.MAX_VALUE : rankBitSumMap.lastKey());
    }

    private long findBitsForRank(long rank) {
        Map.Entry<Long, Long> floorEntry = rankBitSumMap.floorEntry(rank);
        return floorEntry == null ? 0 : floorEntry.getValue();
    }

    @Override
    public Packet poll() {
        reentrantLock.lock();
        try {
            for (int i = 0; i < queueList.size(); i++) {
                QueueInfo qInfo = queueList.get(i);
                if (!qInfo.queue.isEmpty()) {
                    Packet packet = qInfo.queue.poll();
                if (packet != null) {
                    qInfo.remainingCapacity++;
                    if (qInfo.queue.isEmpty() && qInfo.child != null) {
                        mergeQueues(qInfo);
                    }   
                    return packet;
                }
            }
        }
            currentRound++;
            return null;
        } finally {
            reentrantLock.unlock();
        }
    }

    private void manageQueues() {
        QueueInfo highestPriorityQueue = queueList.isEmpty() ? null : queueList.get(0);
        if (highestPriorityQueue != null) {
            if (highestPriorityQueue.remainingCapacity > 0 && highestPriorityQueue.child == null) {
                splitQueue(highestPriorityQueue);
            }
            if (highestPriorityQueue.queue.isEmpty() && highestPriorityQueue.child != null) {
                mergeQueues(highestPriorityQueue);
            }
        }
    }

    private void splitQueue(QueueInfo parent) {
        if (parent.remainingCapacity > 1) {
            long childCapacity = parent.remainingCapacity;
            QueueInfo child = new QueueInfo(childCapacity, queueList.size());
            parent.child = child;
            parent.remainingCapacity -= childCapacity;
            queueList.add(child);
        }
    }

    private void mergeQueues(QueueInfo parent) {
        if (parent.child == null) return;
        parent.child.remainingCapacity += parent.remainingCapacity;
        queueList.remove(parent);
        parent.child = null;
    }

    @Override
    public int size() {
        return queueList.stream().mapToInt(qInfo -> qInfo.queue.size()).sum();
    }

    @Override
    public boolean isEmpty() {
        return queueList.stream().allMatch(qInfo -> qInfo.queue.isEmpty());
    }

    @Override
    public boolean contains(Object o) {
        return false;
    }

    @Override
    public Iterator<Packet> iterator() {
        return null;
    }

    @Override
    public Object[] toArray() {
        return new Object[0];
    }

    @Override
    public <T> T[] toArray(T[] a) {
        return null;
    }

    @Override
    public boolean add(Packet packet) {
        return false;
    }

    @Override
    public boolean remove(Object o) {
        return false;
    }

    @Override
    public boolean containsAll(Collection<?> c) {
        return false;
    }

    @Override
    public boolean addAll(Collection<? extends Packet> c) {
        return false;
    }

    @Override
    public boolean removeAll(Collection<?> c) {
        return false;
    }

    @Override
    public boolean retainAll(Collection<?> c) {
        return false;
    }

    @Override
    public void clear() {
    }

    @Override
    public Packet remove() {
        return null;
    }

    @Override
    public Packet element() {
        return null;
    }

    @Override
    public Packet peek() {
        return null;
    }
}
