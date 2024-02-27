import os
from locust import HttpUser, task, between
from requests.auth import HTTPBasicAuth

class ElasticsearchUser(HttpUser):
    wait_time = between(1, 2)  # Time between tasks for each user

    es_pass = os.environ['ES_PASSWORD']
    es_user = os.environ['ES_USER']

    @task
    def perform_query(self):
        query = {
            "query": {
                "bool": {
                "must": [
                    {
                    "match": {
                        "title": {
                        "query": "How to configure an Ingress on Kubernetes",
                        "boost": 1
                        }
                    }
                    }
                ],
                "filter": [
                    {
                    "exists": {
                        "field": "ml.inference.title-vector.predicted_value"
                    }
                    }
                ]
                }
            },
            "knn": {
                "field": "ml.inference.title-vector.predicted_value",
                "k": 1,
                "num_candidates": 20,
                "query_vector_builder": {
                "text_embedding": {
                    "model_id": "sentence-transformers__all-distilroberta-v1",
                    "model_text": "How to configure an Ingress on Kubernetes"
                }
                },
                "boost": 24
            },
            "fields": [
                "title",
                "body_content",
                "url"
            ],
            "_source": [],
            "size": 1
            }
        index = 'search-elastic-docs'
        headers = {"Content-Type": "application/json"}
        auth = HTTPBasicAuth(self.es_user, self.es_pass)
        root_ca = '/tmp/ca.crt'
        self.client.post(f"/{index}/_search", json=query, headers=headers, auth=auth, verify=root_ca)