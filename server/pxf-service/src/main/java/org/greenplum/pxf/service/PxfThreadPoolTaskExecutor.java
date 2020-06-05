package org.greenplum.pxf.service;

import org.greenplum.pxf.api.error.PxfRuntimeException;
import org.springframework.core.task.TaskRejectedException;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.util.concurrent.Callable;
import java.util.concurrent.Future;

public class PxfThreadPoolTaskExecutor extends ThreadPoolTaskExecutor {

    private static final String PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_MESSAGE = "PXF Server processing capacity exceeded.";
    private static final String PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_HINT = "Consider increasing the values of PXF_TASK_POOL_MAX_SIZE and/or PXF_TASK_POOL_QUEUE_CAPACITY in $PXF_CONF/conf/pxf-env.sh";

    @Override
    public Future<?> submit(Runnable task) {
        try {
            return super.submit(task);
        } catch (TaskRejectedException ex) {

            // TODO: set PXF_CONF as a system property

            PxfRuntimeException exception = new PxfRuntimeException(
                    PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_MESSAGE,
                    /*String.format()*/ PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_HINT,
                    ex.getCause());

            throw new TaskRejectedException(ex.getMessage(), exception);
        }
    }

    @Override
    public <T> Future<T> submit(Callable<T> task) {
        try {
            return super.submit(task);
        } catch (TaskRejectedException ex) {

            PxfRuntimeException exception = new PxfRuntimeException(
                    PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_MESSAGE,
                    /*String.format()*/ PXF_SERVER_PROCESSING_CAPACITY_EXCEEDED_HINT,
                    ex.getCause());

            throw new TaskRejectedException(ex.getMessage(), exception);
        }
    }
}
