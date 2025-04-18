public with sharing class TaskController {
    public static List<Task__c> getAllTasks() {
        return [SELECT Id, Name, Description__c FROM Task__c WHERE CreatedDate = THIS_MONTH WITH SECURITY_ENFORCED];
    }
}