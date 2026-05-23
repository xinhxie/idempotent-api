import boto3
import time
import hashlib
from botocore.exceptions import ClientError

dynamodb = boto3.client('dynamodb')
TABLE_NAME = 'idempotent-transactions-table'

def lambda_handler(event, context):
    # In a real scenario, these are extracted from the API Gateway 'event' payload
    account_id = event.get('account_id')
    idempotency_key = event.get('headers', {}).get('Idempotency-Key')
    amount = event.get('amount')
    request_body = str(event.get('body')) 

    payload_hash = hashlib.sha256(request_body.encode()).hexdigest()
    ttl_expiration = int(time.time()) + 24 * 60 * 60 # 24 hours

    try:
        response = dynamodb.transact_write_items(
            TransactItems=[
                {
                    'Put': {
                        'TableName': TABLE_NAME,
                        'Item': {
                            'PK': {'S': f'IDEMPOTENCY#{idempotency_key}'},
                            'SK': {'S': 'TRANSACTION'},
                            'request_hash': {'S': payload_hash},
                            'status': {'S': 'SUCCESS'},
                            'expiration_time': {'N': str(ttl_expiration)}
                        },
                        'ConditionExpression': 'attribute_not_exists(PK)'
                    }
                },
                {
                    'Update': {
                        'TableName': TABLE_NAME,
                        'Key': {
                            'PK': {'S': f'ACCOUNT#{account_id}'},
                            'SK': {'S': 'PROFILE'}
                        },
                        'UpdateExpression': 'SET balance = balance - :amount',
                        'ExpressionAttributeValues': {
                            ':amount': {'N': str(amount)},
                            ':zero': {'N': '0'}
                        },
                        'ConditionExpression': 'balance >= :zero'
                    }
                }
            ]
        )
        return {"statusCode": 200, "body": "Transaction processed successfully"}
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'TransactionCanceledException':
            return {"statusCode": 409, "body": "Transaction failed: Idempotency conflict or insufficient funds."}
        raise e