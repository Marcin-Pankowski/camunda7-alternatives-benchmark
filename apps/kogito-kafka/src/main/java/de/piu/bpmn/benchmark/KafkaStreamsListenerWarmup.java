package de.piu.bpmn.benchmark;

import io.quarkus.arc.ClientProxy;
import io.quarkus.runtime.StartupEvent;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import org.kie.kogito.persistence.kafka.KafkaStreamsStateListener;

/**
 * Works around a startup race in Kogito 10.2.0's Kafka persistence. KafkaStreamsStateListener registers itself with
 * setStateListener when its bean is created. Quarkus starts Kafka Streams in its own StartupEvent observer; if the
 * listener bean does not exist yet, the first state change (REBALANCING) creates it, setStateListener throws
 * IllegalStateException and the app never becomes ready. Creating the bean before that observer avoids the race.
 */
@ApplicationScoped
public class KafkaStreamsListenerWarmup {

    void createListenerBeforeStreamsStart(@Observes @Priority(1) StartupEvent event, KafkaStreamsStateListener listener) {
        ClientProxy.unwrap(listener); // the injected client proxy is lazy; unwrapping creates the real bean now
    }
}
