pipeline {
    agent {
        label 'ansible-agent'
    }

    options {
        disableConcurrentBuilds()
        timestamps()
    }

    parameters {
        booleanParam(
            name: 'CONFIGURE_NGINX',
            defaultValue: false,
            description: '공용 Nginx의 sohyeon.conf를 설정/변경할 때만 활성화'
        )
    }

    environment {
        IMAGE_NAME = 'sohyeon-cicd-app'
        TEST_CONTAINER = 'sohyeon-cicd-test'
        NGINX_URL = 'http://1.201.116.156:18007'
    }

    stages {

        stage('Check Environment') {
            steps {
                sh '''
                    echo "=== Jenkins Agent ==="
                    hostname
                    whoami
                    pwd

                    echo "=== Required Tools ==="
                    docker --version
                    ansible --version
                    git --version
                    curl --version
                    ssh -V
                '''
            }
        }


        stage('Build') {
            steps {
                sh '''
                    echo "=== Build Docker Image ==="

                    docker build \
                      -t ${IMAGE_NAME}:${BUILD_NUMBER} .
                '''
            }
        }


        stage('Test') {
            steps {
                sh '''
                    echo "=== Test Docker Image ==="

                    docker rm -f ${TEST_CONTAINER} \
                      2>/dev/null || true

                    docker run -d \
                      --name ${TEST_CONTAINER} \
                      -e APP_VERSION=v${BUILD_NUMBER} \
                      ${IMAGE_NAME}:${BUILD_NUMBER}

                    sleep 2

                    HEALTH_RESULT=$(
                      docker exec ${TEST_CONTAINER} \
                      wget -qO- http://127.0.0.1/health
                    )

                    VERSION_RESULT=$(
                      docker exec ${TEST_CONTAINER} \
                      wget -qO- http://127.0.0.1/version
                    )

                    echo "health=${HEALTH_RESULT}"
                    echo "version=${VERSION_RESULT}"

                    test "${HEALTH_RESULT}" = "OK"
                    test "${VERSION_RESULT}" = "v${BUILD_NUMBER}"

                    docker rm -f ${TEST_CONTAINER}
                '''
            }
        }


        stage('Prepare Artifact') {
            steps {
                sh '''
                    echo "=== Prepare Deployment Artifact ==="

                    mkdir -p .artifacts

                    docker save \
                      -o .artifacts/${IMAGE_NAME}.tar \
                      ${IMAGE_NAME}:${BUILD_NUMBER}
                '''
            }
        }


        stage('Prepare SSH') {
            steps {
                sh '''
                    echo "=== Prepare Private known_hosts ==="

                    mkdir -p .ssh
                    chmod 700 .ssh

                    : > .ssh/known_hosts

                    ssh-keyscan -H \
                      1.201.118.202 \
                      1.201.118.10 \
                      1.201.118.90 \
                      1.201.116.156 \
                      >> .ssh/known_hosts

                    chmod 600 .ssh/known_hosts
                '''
            }
        }


        stage('Deploy') {
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'sohyeon-deploy-ssh',
                        keyFileVariable: 'SSH_KEY',
                        usernameVariable: 'SSH_USER'
                    )
                ]) {
                    sh '''
                        echo "=== Deploy to App Servers ==="

                        export ANSIBLE_PRIVATE_KEY_FILE="${SSH_KEY}"
                        export ANSIBLE_REMOTE_USER="${SSH_USER}"
                        export ANSIBLE_SSH_ARGS="-o UserKnownHostsFile=${WORKSPACE}/.ssh/known_hosts -o StrictHostKeyChecking=yes"

                        ansible-playbook \
                          -i ansible/inventory.ini \
                          ansible/deploy.yml \
                          --limit app_servers \
                          -e "image_name=${IMAGE_NAME}" \
                          -e "image_tag=${BUILD_NUMBER}" \
                          -e "image_tar=${WORKSPACE}/.artifacts/${IMAGE_NAME}.tar"
                    '''
                }
            }
        }


        stage('Configure Nginx') {
            when {
                expression {
                    return params.CONFIGURE_NGINX
                }
            }

            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'sohyeon-deploy-ssh',
                        keyFileVariable: 'SSH_KEY',
                        usernameVariable: 'SSH_USER'
                    )
                ]) {
                    sh '''
                        echo "=== Configure Sohyeon Nginx ==="

                        export ANSIBLE_PRIVATE_KEY_FILE="${SSH_KEY}"
                        export ANSIBLE_REMOTE_USER="${SSH_USER}"
                        export ANSIBLE_SSH_ARGS="-o UserKnownHostsFile=${WORKSPACE}/.ssh/known_hosts -o StrictHostKeyChecking=yes"

                        ansible-playbook \
                          -i ansible/inventory.ini \
                          ansible/nginx.yml \
                          --limit load_balancer
                    '''
                }
            }
        }


        stage('Verify') {
            steps {
                sh '''
                    echo "=== Verify Through Nginx ==="

                    HEALTH_RESULT=$(
                      curl --fail --silent \
                      ${NGINX_URL}/health
                    )

                    VERSION_RESULT=$(
                      curl --fail --silent \
                      ${NGINX_URL}/version
                    )

                    echo "health=${HEALTH_RESULT}"
                    echo "version=${VERSION_RESULT}"

                    test "${HEALTH_RESULT}" = "OK"
                    test "${VERSION_RESULT}" = "v${BUILD_NUMBER}"
                '''
            }
        }
    }


    post {
        always {
            sh '''
                echo "=== Cleanup Sohyeon temporary resources ==="

                docker rm -f ${TEST_CONTAINER} \
                  2>/dev/null || true

                rm -rf .artifacts
                rm -rf .ssh
            '''
        }

        success {
            echo 'Sohyeon CI/CD Pipeline SUCCESS'
        }

        failure {
            echo 'Sohyeon CI/CD Pipeline FAILED'
        }
    }
}