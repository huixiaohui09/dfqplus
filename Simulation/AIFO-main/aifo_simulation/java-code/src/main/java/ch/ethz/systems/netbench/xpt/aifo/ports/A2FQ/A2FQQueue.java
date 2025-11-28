package ch.ethz.systems.netbench.xpt.aifo.ports.A2FQ;

import ch.ethz.systems.netbench.core.network.Packet;
import ch.ethz.systems.netbench.xpt.tcpbase.FullExtTcpPacket;

import java.util.*;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.locks.ReentrantLock;

public class A2FQQueue implements Queue<Packet> {

    private final ArrayList<ArrayBlockingQueue<Packet>> queueList;
    private final Map<Long, Long> flowBids;
    private final long bytesPerRound;
    private long currentRound;
    private long servingQueue;
    private final ReentrantLock reentrantLock;
    private final int ownId;

    private int Nq;  // Number of available queues
    private int Nq_star;   // Number of effective queues
    private int qid_longest;  // Queue index of the longest queue
    private long T_t;  // Threshold limiting the queue length

    private final long maxBufferSize;
    private long currentBufferSize;

    public A2FQQueue(long numQueues, long perQueueCapacity, long bytesPerRound, int ownId) {
        this.Nq = (int) numQueues;
        this.Nq_star = this.Nq;
        this.bytesPerRound = bytesPerRound;
        this.maxBufferSize = numQueues * perQueueCapacity * 1500;
        this.currentBufferSize = 0;
        this.currentRound = 0;
        this.servingQueue = 0;
        this.qid_longest = 0;
        this.ownId = ownId;

        this.flowBids = new HashMap<>();
        this.reentrantLock = new ReentrantLock();

        updateThreshold();

        this.queueList = new ArrayList<>(this.Nq);
        for (int i = 0; i < this.Nq; i++) {
            this.queueList.add(new ArrayBlockingQueue<>((int) T_t));
        }
    }

    private void updateThreshold() {
        this.T_t = maxBufferSize / (1 + Nq_star);
        if (queueList != null) {
            for (int i = 0; i < Nq_star; i++) {
                ArrayBlockingQueue<Packet> newQueue = new ArrayBlockingQueue<>((int) T_t);
                if (queueList.get(i) != null) {
                    newQueue.addAll(queueList.get(i));
                }
                queueList.set(i, newQueue);
            }
        }
    }

    @Override
    public boolean offer(Packet packet) {
        if (!(packet instanceof FullExtTcpPacket)) {
            return false;
        }

        FullExtTcpPacket p = (FullExtTcpPacket) packet;
        reentrantLock.lock();
        try {
            long pktLength = p.getSizeBit() / 8;  // Convert to bytes

            // Get total enqueued data for the flow
            long totalEnq = flowBids.getOrDefault(p.getFlowId(), currentRound * bytesPerRound);

            // Make laggard flows catch up
            totalEnq = Math.max(totalEnq, currentRound * bytesPerRound);
            totalEnq += pktLength;

            // Find the logical queue id to put the packet in
            long qid_target = totalEnq / bytesPerRound;

            if (qid_target >= currentRound + Nq_star) {
                // The flow has enqueued too much data
                return false;
            }

            // Shared buffer management
            int physicalQueueId = (int)(qid_target % Nq);
            if (queueList.get(physicalQueueId).size() + 1 > T_t || currentBufferSize + pktLength > maxBufferSize) {
                return false;
            }

            // Enqueue the packet
            if (queueList.get(physicalQueueId).offer(p)) {
                flowBids.put(p.getFlowId(), totalEnq);
                currentBufferSize += pktLength;

                // Update the longest queue index
                if (queueList.get(qid_longest).size() < queueList.get(physicalQueueId).size()) {
                    qid_longest = physicalQueueId;
                }

                return true;
            }

            return false;
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public Packet poll() {
        reentrantLock.lock();
        try {
            if (isEmpty()) {
                return null;
            }

            Packet p = null;
            while (p == null) {
                if (this.size() != 0) {
                    if (!queueList.get((int) this.servingQueue).isEmpty()) {
                        p = queueList.get((int) this.servingQueue).poll();
                        currentBufferSize -= p.getSizeBit() / 8;

                        // Adjust the number of effective queues based on the longest queue length
                        if (queueList.get(qid_longest).size() > T_t * 0.8) {  // Qhigh
                            Nq_star = Math.max(Nq_star - 1, 2);
                            updateThreshold();
                        } else if (queueList.get(qid_longest).size() < T_t * 0.2) {  // Qlow
                            Nq_star = Math.min(Nq_star + 1, Nq);
                            updateThreshold();
                        }

                        return p;
                    } else {
                        this.servingQueue = (this.servingQueue + 1) % this.Nq;
                        this.currentRound++;
                    }
                } else {
                    break;
                }
            }
            return null;
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public int size() {
        int size = 0;
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            size += queue.size();
        }
        return size;
    }

    @Override
    public boolean isEmpty() {
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            if (!queue.isEmpty()) {
                return false;
            }
        }
        return true;
    }

    @Override
    public boolean contains(Object o) {
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            if (queue.contains(o)) {
                return true;
            }
        }
        return false;
    }

    @Override
    public Iterator<Packet> iterator() {
        return new Iterator<Packet>() {
            private int queueIndex = 0;
            private Iterator<Packet> currentQueueIterator = queueList.get(0).iterator();

            @Override
            public boolean hasNext() {
                while (!currentQueueIterator.hasNext() && queueIndex < queueList.size() - 1) {
                    queueIndex++;
                    currentQueueIterator = queueList.get(queueIndex).iterator();
                }
                return currentQueueIterator.hasNext();
            }

            @Override
            public Packet next() {
                if (!hasNext()) {
                    throw new NoSuchElementException();
                }
                return currentQueueIterator.next();
            }
        };
    }

    @Override
    public Object[] toArray() {
        List<Packet> allPackets = new ArrayList<>();
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            allPackets.addAll(queue);
        }
        return allPackets.toArray();
    }

    @Override
    public <T> T[] toArray(T[] a) {
        List<Packet> allPackets = new ArrayList<>();
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            allPackets.addAll(queue);
        }
        return allPackets.toArray(a);
    }

    @Override
    public boolean add(Packet packet) {
        return offer(packet);
    }

    @Override
    public boolean remove(Object o) {
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            if (queue.remove(o)) {
                currentBufferSize -= ((Packet) o).getSizeBit() / 8;
                return true;
            }
        }
        return false;
    }

    @Override
    public boolean containsAll(Collection<?> c) {
        for (Object o : c) {
            if (!contains(o)) {
                return false;
            }
        }
        return true;
    }

    @Override
    public boolean addAll(Collection<? extends Packet> c) {
        boolean modified = false;
        for (Packet packet : c) {
            if (offer(packet)) {
                modified = true;
            }
        }
        return modified;
    }

    @Override
    public boolean removeAll(Collection<?> c) {
        boolean modified = false;
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            int sizeBefore = queue.size();
            if (queue.removeAll(c)) {
                currentBufferSize -= (sizeBefore - queue.size()) * 1500; // Assuming average packet size
                modified = true;
            }
        }
        return modified;
    }

    @Override
    public boolean retainAll(Collection<?> c) {
        boolean modified = false;
        for (ArrayBlockingQueue<Packet> queue : queueList) {
            int sizeBefore = queue.size();
            if (queue.retainAll(c)) {
                currentBufferSize -= (sizeBefore - queue.size()) * 1500; // Assuming average packet size
                modified = true;
            }
        }
        return modified;
    }

    @Override
    public void clear() {
        reentrantLock.lock();
        try {
            for (ArrayBlockingQueue<Packet> queue : queueList) {
                queue.clear();
            }
            currentBufferSize = 0;
            flowBids.clear();
            Nq_star = Nq;
            qid_longest = 0;
            currentRound = 0;
            servingQueue = 0;
            updateThreshold();
        } finally {
            reentrantLock.unlock();
        }
    }

    @Override
    public Packet remove() {
        Packet p = poll();
        if (p == null) {
            throw new NoSuchElementException();
        }
        return p;
    }

    @Override
    public Packet element() {
        Packet p = peek();
        if (p == null) {
            throw new NoSuchElementException();
        }
        return p;
    }

    @Override
    public Packet peek() {
        reentrantLock.lock();
        try {
            for (ArrayBlockingQueue<Packet> queue : queueList) {
                Packet packet = queue.peek();
                if (packet != null) return packet;
            }
            return null;
        } finally {
            reentrantLock.unlock();
        }
    }

    public int getEffectiveQueueNumber() {
        return Nq_star;
    }

    public long getCurrentRound() {
        return currentRound;
    }
}