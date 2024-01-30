ARG AIRFLOW_VERSION=2.8.0
ARG PYTHON_VERSION=3.10

FROM apache/airflow:slim-${AIRFLOW_VERSION}-python${PYTHON_VERSION}

COPY requirements.txt .

RUN pip install --upgrade pip && \
    pip install -r requirements.txt && \
    rm requirements.txt
